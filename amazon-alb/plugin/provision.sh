#!/bin/bash
# exit when any command fails
set -e

# Install jq
curl  -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /bin/jq
chmod +x /bin/jq

if [ "$VISIBILITY" = "private" ]; then
    SCHEME="internal"
else
    SCHEME="external"
fi
SANDBOX_ID=$SIGNADOT_SANDBOX_ROUTING_KEY
# We have to extract this from devops repo or something
ACTUAL_NODEPORT=30004
START_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 600 ))
END_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 699 ))
# Get ARN of ALB in question based on its tags
ALB_ARN=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Scheme,Values=$SCHEME --tag-filters Key=Name,Values=$APP --resource-type-filters elasticloadbalancing | jq -r '.ResourceTagMappingList[0].ResourceARN')
echo "ALB ARN: $ALB_ARN"

# Get ARN of the ALB Listener, so that we can add listener rules to it
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN | jq -r '.Listeners[0].ListenerArn')
echo "Listener ARN: $LISTENER_ARN"

# Get VPC ID of the app
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$FAMILY-$VISIBILITY | jq -r '.Vpcs[0].VpcId')
echo "VPC ID: $VPC_ID"

# Get instance IDs to attach to the target group
NODE_GROUP=$(aws eks list-nodegroups --cluster-name $FAMILY-$VISIBILITY-$ENVIRONMENT | jq -r '.nodegroups[0]')
echo "Node group: $NODE_GROUP"
ASG_NAME=$(aws eks describe-nodegroup --cluster-name $FAMILY-$VISIBILITY-$ENVIRONMENT --nodegroup-name $NODE_GROUP --query "nodegroup.resources.autoScalingGroups[0].name" --output text)
echo "ASG Name: $ASG_NAME"
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-2ebe03b9-6fc8-db8f-6f4f-7ae7e8468cbb --query "AutoScalingGroups[0].Instances[*].InstanceId" --output text)
# Format the instance IDs for register-targets command
TARGETS=$(for ID in $INSTANCE_IDS; do echo "Id=$ID "; done)
echo "Instance IDs: $TARGETS"

# Find next available nodePort
USED_PORTS=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=app,Values=$APP --tag-filters Key=Environment,Values=$ENVIRONMENT --tag-filters Key=isSandbox,Values=true \
    --resource-type-filters elasticloadbalancing \
    --query 'ResourceTagMappingList[*].Tags[?Key==`nodePort`].Value' \
    --output text | tr '\t' '\n' | sort -n)

NODEPORT=""
for PORT in $(seq $START_NODEPORT_RANGE $END_NODEPORT_RANGE); do
  if ! echo "$USED_PORTS" | grep -q "^$PORT$"; then
    NODEPORT=$PORT
    break
  fi
done

if [ -z "$NODEPORT" ]; then
  echo "No available nodePort in the range $START_NODEPORT_RANGE-$END_NODEPORT_RANGE."
  exit 1
fi

echo "The next available nodePort is: $NODEPORT"

# Create Target group to point to the sandbox service in K8S
TARGET_GROUP_NAME=$(echo "eks-$APP-$ENVIRONMENT-${SANDBOX_ID}" | cut -c1-32)
TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name $TARGET_GROUP_NAME --protocol HTTP --port $NODEPORT \
    --vpc-id $VPC_ID --target-type instance --health-check-path "/health" --health-check-interval-seconds 10 \
    --healthy-threshold-count 2 \
    --tags Key=Environment,Value=$ENVIRONMENT Key=Family,Value=$FAMILY Key=sandboxId,Value=$SANDBOX_ID Key=nodePort,Value=$NODEPORT Key=app,Value=$APP Key=isSandbox,Value=true \
    | jq -r '.TargetGroups[0].TargetGroupArn')
# Register EKS ASG instances to the target group
REGISTER_TARGET_GROUP=$(aws elbv2 register-targets --target-group-arn $TARGET_GROUP_ARN --targets $TARGETS)

# Get the rules for the listener
LISTENER_RULES=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN")

# Get the next priority number for the listener rule
MAX_PRIORITY=$(echo "$LISTENER_RULES" | jq -r '.Rules | map(select(.Priority != "default")) | map(.Priority | tonumber) | max // 0')
# Calculate the next available priority
NEXT_PRIORITY=$((MAX_PRIORITY + 1))
echo "The next available priority is: $NEXT_PRIORITY"

# Create listener rule to point to the created target group when sandbox header values exist
RULE_ARN=$(aws elbv2 create-rule --listener-arn $LISTENER_ARN --conditions "Field=http-header,HttpHeaderConfig={HttpHeaderName=uberctx-sd-sandbox,Values=[$SANDBOX_ID]}" --actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN --priority $NEXT_PRIORITY | jq -r '.Rules[0].RuleArn')
echo "Rule created: $RULE_ARN"

# Open security group for ALB, private worker and application

# Populate output
echo -n "${RULE_ARN}" > /tmp/rule-arn
echo -n "${TARGET_GROUP_ARN}" > /tmp/target-group-arn

# Need to output nodePort for the current targetGroup. This will be used for the k8s service to be deployed next in the pipeline