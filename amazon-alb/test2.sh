ACTUAL_NODEPORT=30004
START_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 600 ))
END_NODEPORT_RANGE=$(( ACTUAL_NODEPORT + 699 ))

USED_PORTS=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=app,Values=e2e-mc --tag-filters Key=Environment,Values=staging --tag-filters Key=isSandbox,Values=true \
    --resource-type-filters elasticloadbalancing \
    --query 'ResourceTagMappingList[*].Tags[?Key==`nodePort`].Value' \
    --output text | tr '\t' '\n' | sort -n)

echo $USED_PORTS
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