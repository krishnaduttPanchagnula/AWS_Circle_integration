# AWS N TERRAFORM ARCHITECTURE
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
#backend added
  backend "s3" {
    bucket = "terraform-backend-for-circle-ci"
    key    = "terraform.tfstate"
    region = "ap-south-1"

    dynamodb_table = "aws-terraform-locks"
    encrypt        = true
  }
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
}

#Extract the current account details
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "logs" {
  name = "Feature_Logs"
}

resource "aws_cloudwatch_log_subscription_filter" "logs_lambdafunction_logfilter" {
name = "logs_lambdafunction_logfilter"
# role_arn = aws_iam_role.iam_for_moni_pre.arn #change
log_group_name = aws_cloudwatch_log_group.logs.name
filter_pattern = "?SQLTransientConnectionException ?Error" // Change the error Patterns here.
destination_arn = aws_lambda_function.logmonitoring_lambda.arn
}


#SNS ARCHITECTURE

resource "aws_sns_topic" "logsns" {
  name = "logsns"
}


resource "aws_sns_topic_subscription" "snstoemail_email-target" {
  topic_arn = aws_sns_topic.logsns.arn
  protocol  = "email"
  endpoint  = var.email
}


# aws_sns_topic_policy.eventtosns:
resource "aws_sns_topic_policy" "logsns_policy" {
  arn = aws_sns_topic.logsns.arn

  policy = data.aws_iam_policy_document.sns_topic_policy.json
  
}
data "aws_iam_policy_document" "sns_topic_policy" {
  policy_id = "__default_policy_ID"

  statement {
    actions = [
      "SNS:Subscribe",
      "SNS:SetTopicAttributes",
      "SNS:RemovePermission",
      "SNS:Receive",
      "SNS:Publish",
      "SNS:ListSubscriptionsByTopic",
      "SNS:GetTopicAttributes",
      "SNS:DeleteTopic",
      "SNS:AddPermission",
    ]

    # condition {
    #   logs     = "StringEquals"
    #   variable = "AWS:SourceOwner"

    #   values = [
    #     "${data.aws_caller_identity.current.account_id}",
    #   ]
    # }

    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      aws_sns_topic.logsns.arn,
    ]

    sid = "__default_statement_ID"
  }
}
  
 
# LAMBDA ARCHITECTURE

# aws_iam_role.iam_for_moni_pre:
resource "aws_iam_role" "iam_for_moni_pre" {

    name                  = "log_monitoring_iam"
    
    assume_role_policy    = jsonencode(
        {
            Statement = [
                {
                    Action    = "sts:AssumeRole"
                    Effect    = "Allow"
                    Principal = {
                        Service = "lambda.amazonaws.com"
                    }
                },
            ]
            Version   = "2012-10-17"
        }
    )
   
    
    
    inline_policy {}
}


# SNS publication policy
resource "aws_iam_policy" "snspublication" {
 name = "snspublication_logs"

 policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
          "Effect": "Allow",
          "Action": [
                "sns:Publish"
                ],
            "Resource": "arn:aws:sns:*:*:*"
        }
    ]
}
EOF
}


resource "aws_iam_role_policy_attachment" "websitemonitoringlambda-snseventpushing" {
  role = aws_iam_role.iam_for_moni_pre.name
  policy_arn = aws_iam_policy.snspublication.arn
     
}

# LOG creation and log publication

resource "aws_cloudwatch_log_group" "example" {
  name              = "/aws/lambda/${aws_lambda_function.logmonitoring_lambda.function_name}"
  retention_in_days = 0
}

# See also the following AWS managed policy: AWSLambdaBasicExecutionRole
resource "aws_iam_policy" "lambda_logging" {
  name        = "lambda_logging_test"
  description = "IAM policy for logging from a lambda"

  policy = jsonencode(
        {
            Statement = [
                {
                    Action   = "logs:CreateLogGroup"
                    Effect   = "Allow"
                    Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
                },
                {
                    Action   = [
                        "logs:CreateLogStream",
                        "logs:PutLogEvents",
                    ]
                    Effect   = "Allow"
                    Resource = [
                        "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${aws_cloudwatch_log_group.example.name}:*"
                    ]
                },
            ]
            Version   = "2012-10-17"
        }
    )
}
   
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.iam_for_moni_pre.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}


data "archive_file" "Resource_monitoring_lambdascript" {
  type        = "zip"
  source_file = "./lambda_function.py"
  output_path = "./lambda_function.zip"
}


# aws_lambda_function.logmonitoring_lambda:
resource "aws_lambda_function" "logmonitoring_lambda" {
    function_name                  = "logmonitoring_lambda"
    filename                       = data.archive_file.Resource_monitoring_lambdascript.output_path
    handler                        = "lambda_function.lambda_handler"
    package_type                   = "Zip"
    
    role                           = aws_iam_role.iam_for_moni_pre.arn
    runtime                        = "python3.9"
    source_code_hash               = filebase64sha256(data.archive_file.Resource_monitoring_lambdascript.output_path)
    
    timeouts {}

    tracing_config {
        mode = "PassThrough"
    }
    environment {
      variables = {
        snsarn = "${aws_sns_topic.logsns.arn}"
      }
    }
}


resource "aws_lambda_permission" "allow_cloudwatch" {
statement_id = "AllowExecutionFromCloudWatch"
action = "lambda:InvokeFunction"
function_name = aws_lambda_function.logmonitoring_lambda.function_name
principal = "logs.${data.aws_region.current.name}.amazonaws.com"
source_arn = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"

}

