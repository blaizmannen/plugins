#!/bin/bash
# exit when any command fails
set -e

echo "Deleting Listener Rule ARN: $RULE_ARN"
aws elbv2 delete-rule --rule-arn $RULE_ARN

echo "Deleting Target Group ARN: $TARGET_GROUP_ARN"
aws elbv2 delete-target-group --target-group-arn $TARGET_GROUP_ARN
