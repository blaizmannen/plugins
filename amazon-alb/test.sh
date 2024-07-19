SANDBOX_ID="asd123"
# We have to extract this from devops repo or something
ACTUAL_NODEPORT=30004
START_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 600 ))
END_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 699 ))
# Get ARN of ALB in question based on its tags
ALB_ARN=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Scheme,Values=internal --tag-filters Key=Name,Values=e2e-mc --resource-type-filters elasticloadbalancing | jq -r '.ResourceTagMappingList[0].ResourceARN')
echo "ALB ARN: $ALB_ARN"

# Get ARN of the ALB Listener, so that we can add listener rules to it
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN | jq -r '.Listeners[0].ListenerArn')
echo "Listener ARN: $LISTENER_ARN"

# Get VPC ID of the app
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=e2e-private | jq -r '.Vpcs[0].VpcId')
echo "VPC ID: $VPC_ID"

# Get instance IDs to attach to the target group
NODE_GROUP=$(aws eks list-nodegroups --cluster-name e2e-private-staging | jq -r '.nodegroups[0]')
echo "Node group: $NODE_GROUP"
ASG_NAME=$(aws eks describe-nodegroup --cluster-name e2e-private-staging --nodegroup-name $NODE_GROUP --query "nodegroup.resources.autoScalingGroups[0].name" --output text)
echo "ASG Name: $ASG_NAME"
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names eks-2ebe03b9-6fc8-db8f-6f4f-7ae7e8468cbb --query "AutoScalingGroups[0].Instances[*].InstanceId" --output text)
# Format the instance IDs for register-targets command
TARGETS=$(for ID in $INSTANCE_IDS; do echo "Id=$ID "; done)
echo "Instance IDs: $TARGETS"

# Find next available nodePort
USED_PORTS=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=app,Values=e2e-mc --tag-filters Key=Environment,Values=staging --tag-filters Key=isSandbox,Values=true \
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
TARGET_GROUP_NAME=$(echo "eks-e2e-mc-staging-${SANDBOX_ID}" | cut -c1-32)
TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name $TARGET_GROUP_NAME --protocol HTTP --port $NODEPORT \
    --vpc-id $VPC_ID --target-type instance --health-check-path "/health" --health-check-interval-seconds 10 \
    --healthy-threshold-count 2 \
    --tags Key=Environment,Value=staging Key=Family,Value=e2e Key=sandboxId,Value=$SANDBOX_ID Key=nodePort,Value=$NODEPORT Key=app,Value=e2e-mc Key=isSandbox,Value=true \
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
CREATE_RULE=$(aws elbv2 create-rule --listener-arn $LISTENER_ARN --conditions "Field=http-header,HttpHeaderConfig={HttpHeaderName=uberctx-sd-sandbox,Values=[$SANDBOX_ID]}" --actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN --priority $NEXT_PRIORITY)


# Need to output nodePort for the current targetGroup. This will be used for the k8s service to be deployed next in the pipeline