#####
# AWS provider
#####

# Retrieve AWS credentials from env variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
provider "aws" {
  region = "${var.aws_region}"
}

#####
# IAM role
#####

data "template_file" "policy_json" {
  template = "${file("${path.module}/template/policy.json.tpl")}"

  vars {}
}

resource "aws_iam_policy" "iam_role_policy" {
  name        = "${var.lambda_name}-tagging-lambda"
  path        = "/"
  description = "Policy for role ${var.lambda_name}-tagging-lambda"
  policy      = "${data.template_file.policy_json.rendered}"
}

resource "aws_iam_role" "iam_role" {
  name = "${var.lambda_name}-tagging-lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "lambda-attach" {
  name       = "${var.lambda_name}-tagging-lambda-attachment"
  roles      = ["${aws_iam_role.iam_role.name}"]
  policy_arn = "${aws_iam_policy.iam_role_policy.arn}"
}

#####
# Lambda Function
#####

# Generate ZIP archive with Lambda

data "template_file" "lambda" {
    template = "${file("${path.module}/template/tagging_lambda.py")}"
    
    vars {
      aws_region = "${var.aws_region}"
      name = "${var.lambda_name}"
      search_tag_key = "${var.search_tag_key}"
      search_tag_value = "${var.search_tag_value}"
      tags = "${jsonencode(var.tags)}"
      timestamp = "${timestamp()}"
    }
}

resource "null_resource" "zip_lambda" {
  triggers {
    template_rendered = "${ data.template_file.lambda.rendered }"
  }

  provisioner "local-exec" {
    command = "cat << EOF > /tmp/tagging_lambda.py\n${ data.template_file.lambda.rendered }\nEOF"
  }

  provisioner "local-exec" {
    command = "zip -j /tmp/tagging_lambda /tmp/tagging_lambda.py"
  }
}

# Create lambda

resource "aws_lambda_function" "tagging" {
  depends_on = ["aws_iam_role.iam_role", "null_resource.zip_lambda"]

  filename      = "/tmp/tagging_lambda.zip"
  function_name = "${var.lambda_name}-tagging-lambda"
  role          = "${aws_iam_role.iam_role.arn}"
  handler       = "tagging_lambda.lambda_handler"
  runtime       = "python2.7"
  timeout       = "60"
  memory_size   = "128"

  tags = "${var.tags}"
}

resource "aws_cloudwatch_event_rule" "tagging" {
  name        = "${var.lambda_name}-tagging-lambda"
  description = "Trigger tagging lambda in periodical intervals"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_lambda_permission" "tagging" {
  statement_id   = "${var.lambda_name}-AllowCloudWatchTrigger"
  action         = "lambda:InvokeFunction"
  function_name  = "${aws_lambda_function.tagging.function_name}"
  principal      = "events.amazonaws.com"
  source_arn     = "${aws_cloudwatch_event_rule.tagging.arn}"
}

resource "aws_cloudwatch_event_target" "tagging" {
  rule      = "${aws_cloudwatch_event_rule.tagging.name}"
  target_id = "${var.lambda_name}-TriggerLambda"
  arn       = "${aws_lambda_function.tagging.arn}"
}