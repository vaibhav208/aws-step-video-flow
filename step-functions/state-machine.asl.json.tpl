{
  "Comment": "AWS-Step-video-Flow — video processing pipeline. Orchestrates: create job record -> validate -> (parallel) thumbnail + metadata -> record media details -> (map) transcode each requested resolution on ECS Fargate -> record completion -> SNS notification. Every DynamoDB write flows through the single 'database' Lambda (single-writer pattern) so Step Functions itself never talks to DynamoDB directly. Every terminal outcome (success, validation failure, processing failure) publishes a best-effort SNS notification before reaching its Succeed/Fail state (Phase 4). Execution input shape: {\"job_id\": string, \"bucket\": string, \"key\": string, \"resolutions\": [string, ...]}. In Phase 4 onward, this execution is normally started automatically by the eventbridge module's trigger Lambda on S3 upload, not manually.",
  "StartAt": "CreateJobRecord",
  "States": {

    "CreateJobRecord": {
      "Type": "Task",
      "Comment": "First write for this job_id. InputPath is the identity selection ($) of the whole execution input; Parameters then reshapes that into the 'database' Lambda's {job_id, create, updates} contract. ResultPath is null because nothing downstream needs the Lambda's own response -- discarding it here keeps the state bag small for the rest of the execution.",
      "Resource": "${database_function_arn}",
      "InputPath": "$",
      "Parameters": {
        "job_id.$": "$.job_id",
        "create": true,
        "updates": {
          "status": "PENDING",
          "input_bucket.$": "$.bucket",
          "input_key.$": "$.key",
          "requested_resolutions.$": "$.resolutions"
        }
      },
      "ResultPath": null,
      "Retry": [
        {
          "Comment": "Standard AWS-recommended retry for Lambda plumbing failures (cold-start race conditions, throttling, SDK-level hiccups) -- not application errors.",
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "Comment": "Anything else (e.g. the job_id already exists) is treated as unexpected -- route to the shared processing-failure handler rather than silently proceeding with a workflow that will only fail later.",
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "ValidateVideo"
    },

    "ValidateVideo": {
      "Type": "Task",
      "Comment": "Calls the validate Lambda (format/size/duration checks against the ALLOWED_FORMATS/MAX_FILE_SIZE_BYTES env vars set in Phase 2). ResultPath merges its {is_valid, validation_errors, file_size, format, ...} response into $.validation without disturbing $.job_id/$.bucket/$.key, which later states still need.",
      "Resource": "${validate_function_arn}",
      "Parameters": {
        "job_id.$": "$.job_id",
        "bucket.$": "$.bucket",
        "key.$": "$.key"
      },
      "ResultPath": "$.validation",
      "TimeoutSeconds": 20,
      "Retry": [
        {
          "Comment": "The validate Lambda raises this itself on a transient S3 HeadObject/GetObject error (network blip, brief eventual-consistency window) -- worth retrying a few times before giving up.",
          "ErrorEquals": ["TransientS3Error"],
          "IntervalSeconds": 1,
          "MaxAttempts": 4,
          "BackoffRate": 2.0
        },
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "Comment": "The uploaded object genuinely doesn't exist -- retrying won't help, this is a permanent validation failure, not a transient error.",
          "ErrorEquals": ["SourceObjectNotFoundError"],
          "ResultPath": "$.error_info",
          "Next": "HandleValidationFailure"
        },
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "IsVideoValid"
    },

    "IsVideoValid": {
      "Type": "Choice",
      "Comment": "Choice state routing on the validate Lambda's own verdict. Only checks the boolean the Lambda already computed -- validation RULES live in the validate function (Phase 2), not duplicated here in ASL.",
      "Choices": [
        {
          "Variable": "$.validation.is_valid",
          "BooleanEquals": true,
          "Next": "ParallelProcessing"
        }
      ],
      "Default": "HandleValidationFailure"
    },

    "HandleValidationFailure": {
      "Type": "Task",
      "Comment": "Persist the FAILED status and validation_errors so operators (and, from Phase 4 onward, the SNS notification) can see exactly why the job was rejected.",
      "Resource": "${database_function_arn}",
      "Parameters": {
        "job_id.$": "$.job_id",
        "updates": {
          "status": "FAILED",
          "failure_stage": "VALIDATION",
          "validation_errors.$": "$.validation.validation_errors"
        }
      },
      "ResultPath": null,
      "Next": "NotifyValidationFailure"
    },

    "NotifyValidationFailure": {
      "Type": "Task",
      "Comment": "Phase 4: best-effort SNS notification. Catch below means an SNS outage (or a bad topic ARN) can never prevent the execution from reaching its real terminal state -- ResultPath null on both the Task and its Catch, since nothing downstream reads the SNS response either way.",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${sns_topic_arn}",
        "Subject": "Video pipeline: validation failed",
        "Message.$": "States.Format('Video pipeline job {} FAILED validation. See the DynamoDB job record (validation_errors) for details.', $.job_id)"
      },
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": null,
          "Next": "ValidationFailedState"
        }
      ],
      "Next": "ValidationFailedState"
    },

    "ValidationFailedState": {
      "Type": "Fail",
      "Comment": "Terminal state for rejected uploads. A distinct Error code (vs ProcessingFailedState below) lets Phase 4's CloudWatch alarms/EventBridge rules distinguish 'bad input' from 'our pipeline broke' at a glance.",
      "Error": "VideoValidationFailed",
      "Cause": "The uploaded video failed format/size/duration validation. See the job's DynamoDB record (validation_errors) for details."
    },

    "ParallelProcessing": {
      "Type": "Parallel",
      "Comment": "Thumbnail generation and metadata extraction touch the same source object but produce independent results and don't depend on each other, so they run concurrently rather than back-to-back. Each branch trims its own output via OutputPath before rejoining, so the Parallel state's ResultPath ends up with two small Lambda responses instead of two full copies of the entire job state.",
      "Branches": [
        {
          "StartAt": "GenerateThumbnail",
          "States": {
            "GenerateThumbnail": {
              "Type": "Task",
              "Comment": "InputPath takes the full branch input ($); Parameters narrows it to just what the thumbnail Lambda needs. ResultPath merges the Lambda's response into $.thumbnail_response; OutputPath then keeps ONLY $.thumbnail_response as this branch's output -- without it, this branch's result would carry a full duplicate copy of $.job_id/$.bucket/etc. into the Parallel result array for no reason.",
              "Resource": "${thumbnail_function_arn}",
              "InputPath": "$",
              "Parameters": {
                "job_id.$": "$.job_id",
                "bucket.$": "$.bucket",
                "key.$": "$.key"
              },
              "ResultPath": "$.thumbnail_response",
              "OutputPath": "$.thumbnail_response",
              "TimeoutSeconds": 45,
              "Retry": [
                {
                  "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
                  "IntervalSeconds": 2,
                  "MaxAttempts": 3,
                  "BackoffRate": 2.0
                }
              ],
              "End": true
            }
          }
        },
        {
          "StartAt": "ExtractMetadata",
          "States": {
            "ExtractMetadata": {
              "Type": "Task",
              "Comment": "Same InputPath/ResultPath/OutputPath pattern as the thumbnail branch, so the two branches' outputs land in the Parallel result array in a symmetric, predictable shape: index 0 = thumbnail response, index 1 = metadata response.",
              "Resource": "${metadata_function_arn}",
              "InputPath": "$",
              "Parameters": {
                "job_id.$": "$.job_id",
                "bucket.$": "$.bucket",
                "key.$": "$.key"
              },
              "ResultPath": "$.metadata_response",
              "OutputPath": "$.metadata_response",
              "TimeoutSeconds": 45,
              "Retry": [
                {
                  "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
                  "IntervalSeconds": 2,
                  "MaxAttempts": 3,
                  "BackoffRate": 2.0
                }
              ],
              "End": true
            }
          }
        }
      ],
      "ResultPath": "$.parallel_results",
      "Catch": [
        {
          "Comment": "If EITHER branch exhausts its retries, Parallel fails the whole state (Standard ASL semantics -- there is no partial-success concept here). Route to the shared processing-failure handler.",
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "RecordMediaDetails"
    },

    "RecordMediaDetails": {
      "Type": "Task",
      "Comment": "Single database write combining both Parallel branch results (index 0 = thumbnail, index 1 = metadata) -- keeps DynamoDB writes centralized through the 'database' Lambda instead of each branch writing independently. Also flips status to PROCESSING now that pre-transcode work is done.",
      "Resource": "${database_function_arn}",
      "Parameters": {
        "job_id.$": "$.job_id",
        "updates": {
          "status": "PROCESSING",
          "thumbnail_key.$": "$.parallel_results[0].thumbnail_key",
          "duration_seconds.$": "$.parallel_results[1].duration_seconds",
          "width.$": "$.parallel_results[1].width",
          "height.$": "$.parallel_results[1].height",
          "video_codec.$": "$.parallel_results[1].video_codec",
          "audio_codec.$": "$.parallel_results[1].audio_codec"
        }
      },
      "ResultPath": null,
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "TranscodeAllResolutions"
    },

    "TranscodeAllResolutions": {
      "Type": "Map",
      "Comment": "Fans out over $.resolutions (default [\"1080p\",\"720p\",\"480p\"] -- extensible to 360p/240p/1440p with no state machine changes, since the video-processor app's RESOLUTION_PRESETS already covers all six). MaxConcurrency caps simultaneous Fargate RunTask calls to stay well under typical account service quotas; ItemSelector builds each iteration's own isolated input from the parent state plus the current array item ($$.Map.Item.Value).",
      "ItemsPath": "$.resolutions",
      "MaxConcurrency": 3,
      "ItemSelector": {
        "job_id.$": "$.job_id",
        "bucket.$": "$.bucket",
        "key.$": "$.key",
        "output_bucket.$": "$.bucket",
        "resolution.$": "$$.Map.Item.Value"
      },
      "ItemProcessor": {
        "ProcessorConfig": {
          "Mode": "INLINE"
        },
        "StartAt": "StaggerLaunch",
        "States": {
          "StaggerLaunch": {
            "Type": "Wait",
            "Comment": "Fixed pre-launch delay so that when several Map iterations start at once (MaxConcurrency 3), their ecs:RunTask calls don't all hit the ECS API in the same instant -- spreads out API load instead of relying purely on the Retry policy below to absorb any resulting throttling.",
            "Seconds": ${ecs_runtask_stagger_seconds},
            "Next": "RunTranscodeTask"
          },
          "RunTranscodeTask": {
            "Type": "Task",
            "Comment": "arn:...:ecs:runTask.sync blocks until the Fargate task reaches a terminal state (not just until it's *launched*) -- required so the Map iteration only completes after the transcode actually finishes. ResultPath merges the (large) ECS RunTask response into $.ecs_result; OutputPath then trims this iteration's output down to just the resolution string, so the Map's aggregated result ($.transcode_results) ends up as a small list like [\"1080p\",\"720p\",\"480p\"] confirming which resolutions completed, not six copies of ECS's full task/attachment/network-interface JSON.",
            "Resource": "arn:aws:states:::ecs:runTask.sync",
            "Parameters": {
              "Cluster": "${ecs_cluster_arn}",
              "TaskDefinition": "${ecs_task_definition_family}",
              "LaunchType": "FARGATE",
              "NetworkConfiguration": {
                "AwsvpcConfiguration": {
                  "Subnets": ${jsonencode(public_subnet_ids)},
                  "SecurityGroups": ["${ecs_task_security_group_id}"],
                  "AssignPublicIp": "ENABLED"
                }
              },
              "Overrides": {
                "ContainerOverrides": [
                  {
                    "Name": "video-processor",
                    "Environment": [
                      {"Name": "JOB_ID", "Value.$": "$.job_id"},
                      {"Name": "SOURCE_BUCKET", "Value.$": "$.bucket"},
                      {"Name": "SOURCE_KEY", "Value.$": "$.key"},
                      {"Name": "RESOLUTION", "Value.$": "$.resolution"},
                      {"Name": "OUTPUT_BUCKET", "Value.$": "$.output_bucket"}
                    ]
                  }
                ]
              }
            },
            "ResultPath": "$.ecs_result",
            "OutputPath": "$.resolution",
            "TimeoutSeconds": 1800,
            "Retry": [
              {
                "Comment": "Only retries ECS-API-level failures to LAUNCH the task (throttling / transient capacity errors) -- NOT the video-processor container's own exit code. A deterministic ffmpeg failure (e.g. corrupt input) won't be fixed by retrying and would just waste Fargate spend re-running it.",
                "ErrorEquals": ["ECS.AmazonECSException", "ECS.LimitExceededException"],
                "IntervalSeconds": 5,
                "MaxAttempts": 3,
                "BackoffRate": 2.0
              }
            ],
            "Catch": [
              {
                "Comment": "Covers States.TaskFailed (container exited non-zero -- e.g. ffmpeg error), States.Timeout (exceeded the 1800s ceiling above -- Step Functions calls ecs:StopTask), and any retry exhaustion from above.",
                "ErrorEquals": ["States.ALL"],
                "ResultPath": "$.error_info",
                "Next": "RecordResolutionFailure"
              }
            ],
            "End": true
          },
          "RecordResolutionFailure": {
            "Type": "Task",
            "Comment": "Fine-grained failure record: WHICH resolution failed and why, distinct from (and in addition to) the job-level FAILED status the top-level Catch below will also record.",
            "Resource": "${database_function_arn}",
            "Parameters": {
              "job_id.$": "$.job_id",
              "updates": {
                "status": "FAILED",
                "failure_stage": "TRANSCODING",
                "failed_resolution.$": "$.resolution",
                "error_info.$": "$.error_info"
              }
            },
            "ResultPath": null,
            "Next": "ResolutionFailed"
          },
          "ResolutionFailed": {
            "Type": "Fail",
            "Comment": "Ends this Map iteration in failure. With no ToleratedFailurePercentage set on the Map state (defaults to 0), a single failed resolution fails the entire Map -- and therefore the whole execution, which is the right behavior for a video pipeline: a job with 2 of 3 resolutions is not a usable success state.",
            "Error": "TranscodingFailed",
            "Cause": "ecs:runTask.sync failed or timed out for this resolution. See the job's DynamoDB record (failed_resolution, error_info) and the /ecs log group for details."
          }
        }
      },
      "ResultPath": "$.transcode_results",
      "Catch": [
        {
          "Comment": "Backstop for Map-level failures not already handled by RecordResolutionFailure inside the iterator (e.g. ItemSelector/ItemsPath errors before any iteration even starts).",
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "RecordJobComplete"
    },

    "RecordJobComplete": {
      "Type": "Task",
      "Comment": "Final DynamoDB write: mark the job SUCCESS and record which resolutions were produced.",
      "Resource": "${database_function_arn}",
      "Parameters": {
        "job_id.$": "$.job_id",
        "updates": {
          "status": "SUCCESS",
          "resolutions_processed.$": "$.transcode_results"
        }
      },
      "ResultPath": null,
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Catch": [
        {
          "Comment": "Defensive: the actual video processing already succeeded at this point, so a failure here is 'we finished but couldn't record it' -- still routed through the same handler so it's visible, not silently swallowed.",
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "HandleProcessingFailure"
        }
      ],
      "Next": "BuildExecutionSummary"
    },

    "BuildExecutionSummary": {
      "Type": "Pass",
      "Comment": "By this point $ has accumulated $.validation, $.parallel_results, $.transcode_results, $.thumbnail_response/etc -- useful for debugging mid-execution but noisy as a final result. Parameters builds a compact summary object; ResultPath \"$\" REPLACES the entire state (rather than merging) so this summary is the whole output; OutputPath \"$\" (the default) then passes it straight through to Succeed unchanged.",
      "InputPath": "$",
      "Parameters": {
        "job_id.$": "$.job_id",
        "status": "SUCCESS",
        "resolutions_processed.$": "$.transcode_results",
        "thumbnail_key.$": "$.parallel_results[0].thumbnail_key",
        "duration_seconds.$": "$.parallel_results[1].duration_seconds"
      },
      "ResultPath": "$",
      "OutputPath": "$",
      "Next": "NotifySuccess"
    },

    "NotifySuccess": {
      "Type": "Task",
      "Comment": "Phase 4: success notification, mirroring the two failure-path notifications above. InputPath/OutputPath both default to identity ($) so this state neither trims nor needs to reshape the summary BuildExecutionSummary just produced -- Parameters below reads job_id off of it, ResultPath null leaves that summary untouched as the state that reaches JobSucceeded, and Catch means an SNS-side failure can't turn an otherwise-successful pipeline run into a failed execution.",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${sns_topic_arn}",
        "Subject": "Video pipeline: job succeeded",
        "Message.$": "States.Format('Video pipeline job {} completed successfully. See the DynamoDB job record (resolutions_processed, thumbnail_key) for details.', $.job_id)"
      },
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": null,
          "Next": "JobSucceeded"
        }
      ],
      "Next": "JobSucceeded"
    },

    "JobSucceeded": {
      "Type": "Succeed",
      "Comment": "Terminal success state. Execution output is exactly the BuildExecutionSummary object built two states earlier (this state's own InputPath/OutputPath default to identity, and NotifySuccess above leaves $ untouched via ResultPath null)."
    },

    "HandleProcessingFailure": {
      "Type": "Task",
      "Comment": "Shared failure handler reached from every Catch below the validation step (Parallel, RecordMediaDetails, the Map, RecordJobComplete). Persists FAILED status plus whatever $.error_info the specific Catch attached.",
      "Resource": "${database_function_arn}",
      "Parameters": {
        "job_id.$": "$.job_id",
        "updates": {
          "status": "FAILED",
          "failure_stage": "PROCESSING",
          "error_info.$": "$.error_info"
        }
      },
      "ResultPath": null,
      "Next": "NotifyProcessingFailure"
    },

    "NotifyProcessingFailure": {
      "Type": "Task",
      "Comment": "Phase 4: best-effort SNS notification, same pattern as NotifyValidationFailure above -- Catch guarantees an SNS-side failure can't mask the real (already-persisted) processing failure.",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${sns_topic_arn}",
        "Subject": "Video pipeline: processing failed",
        "Message.$": "States.Format('Video pipeline job {} FAILED during processing. See the DynamoDB job record (failure_stage, error_info) and CloudWatch Logs for details.', $.job_id)"
      },
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": null,
          "Next": "ProcessingFailedState"
        }
      ],
      "Next": "ProcessingFailedState"
    },

    "ProcessingFailedState": {
      "Type": "Fail",
      "Comment": "Terminal state for any post-validation failure (thumbnail/metadata/transcoding/unexpected errors). Distinct Error code from ValidationFailedState so Phase 4's CloudWatch alarms can alert differently on 'our pipeline broke' vs 'the user uploaded something invalid'.",
      "Error": "MediaProcessingFailed",
      "Cause": "Video processing failed after validation succeeded. See the job's DynamoDB record (failure_stage, error_info) and CloudWatch Logs for details."
    }
  }
}
