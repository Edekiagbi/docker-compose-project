#!/bin/bash
set -euo pipefail

# ============================================================
# Deploy Online Boutique to AWS ECS Fargate
# ============================================================
# Usage:
#   ./deploy-ecs.sh <AWS_ACCOUNT_ID> [AWS_REGION]
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Docker images already pushed to ECR (run build-and-push.sh first)
# ============================================================

AWS_ACCOUNT_ID="${1:?Usage: $0 <AWS_ACCOUNT_ID> [AWS_REGION]}"
AWS_REGION="${2:-us-east-1}"
ECR_REPO="online-boutique"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
CLUSTER_NAME="online-boutique-cluster"
SERVICE_NAME="online-boutique-service"
TASK_FAMILY="online-boutique-task"
ALB_NAME="online-boutique-alb"
VPC_NAME="online-boutique-vpc"
TAG="latest"

echo "============================================"
echo "  Deploying Online Boutique to ECS Fargate"
echo "  Region: ${AWS_REGION}"
echo "  Account: ${AWS_ACCOUNT_ID}"
echo "============================================"

# --------------------------------------------
# 1. Get default VPC and subnets
# --------------------------------------------
echo ""
echo "==> Step 1: Fetching VPC and subnet information..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region "${AWS_REGION}")

if [ "${VPC_ID}" = "None" ] || [ -z "${VPC_ID}" ]; then
  echo "ERROR: No default VPC found. Please create one or specify a VPC."
  exit 1
fi
echo "  Default VPC: ${VPC_ID}"

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[*].SubnetId" \
  --output text \
  --region "${AWS_REGION}")
echo "  Subnets: ${SUBNET_IDS}"

# --------------------------------------------
# 2. Create Security Group for ALB
# --------------------------------------------
echo ""
echo "==> Step 2: Creating ALB security group..."

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "online-boutique-alb-sg" \
  --description "Security group for Online Boutique ALB" \
  --vpc-id "${VPC_ID}" \
  --query "GroupId" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=online-boutique-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "${AWS_REGION}")

# Allow inbound HTTP
aws ec2 authorize-security-group-ingress \
  --group-id "${ALB_SG_ID}" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region "${AWS_REGION}" 2>/dev/null || true

echo "  ALB Security Group: ${ALB_SG_ID}"

# --------------------------------------------
# 3. Create Security Group for ECS Tasks
# --------------------------------------------
echo ""
echo "==> Step 3: Creating ECS task security group..."

ECS_SG_ID=$(aws ec2 create-security-group \
  --group-name "online-boutique-ecs-sg" \
  --description "Security group for Online Boutique ECS tasks" \
  --vpc-id "${VPC_ID}" \
  --query "GroupId" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=online-boutique-ecs-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "${AWS_REGION}")

# Allow all traffic from ALB security group
aws ec2 authorize-security-group-ingress \
  --group-id "${ECS_SG_ID}" \
  --protocol -1 \
  --source-group "${ALB_SG_ID}" \
  --region "${AWS_REGION}" 2>/dev/null || true

echo "  ECS Security Group: ${ECS_SG_ID}"

# --------------------------------------------
# 4. Create ALB
# --------------------------------------------
echo ""
echo "==> Step 4: Creating Application Load Balancer..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${ALB_NAME}" \
  --subnets ${SUBNET_IDS} \
  --security-groups "${ALB_SG_ID}" \
  --scheme internet-facing \
  --type application \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || \
  aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text \
    --region "${AWS_REGION}")

echo "  ALB ARN: ${ALB_ARN}"

# Wait for ALB to be active
echo "  Waiting for ALB to become active..."
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "${ALB_ARN}" \
  --region "${AWS_REGION}" 2>/dev/null || true

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query "LoadBalancers[0].DNSName" \
  --output text \
  --region "${AWS_REGION}")
echo "  ALB DNS: ${ALB_DNS}"

# --------------------------------------------
# 5. Create Target Group (frontend on port 8080)
# --------------------------------------------
echo ""
echo "==> Step 5: Creating target group for frontend..."

TG_ARN=$(aws elbv2 create-target-group \
  --name "online-boutique-frontend-tg" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "${VPC_ID}" \
  --target-type ip \
  --health-check-path "/_healthz" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || \
  aws elbv2 describe-target-groups \
    --names "online-boutique-frontend-tg" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text \
    --region "${AWS_REGION}")

echo "  Target Group ARN: ${TG_ARN}"

# --------------------------------------------
# 6. Create Listener on ALB
# --------------------------------------------
echo ""
echo "==> Step 6: Creating ALB listener..."

aws elbv2 create-listener \
  --load-balancer-arn "${ALB_ARN}" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="${TG_ARN}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "  Listener created: HTTP:80 -> frontend target group"

# --------------------------------------------
# 7. Create ECS Cluster
# --------------------------------------------
echo ""
echo "==> Step 7: Creating ECS cluster..."

aws ecs create-cluster \
  --cluster-name "${CLUSTER_NAME}" \
  --tags "key=Project,Value=online-boutique" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "  Cluster: ${CLUSTER_NAME}"

# --------------------------------------------
# 8. Create Task Execution Role
# --------------------------------------------
echo ""
echo "==> Step 8: Creating task execution role..."

# Create the trust policy file
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

EXECUTION_ROLE_ARN=$(aws iam get-role \
  --role-name "online-boutique-execution-role" \
  --query "Role.Arn" \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || echo "")

if [ -z "${EXECUTION_ROLE_ARN}" ] || [ "${EXECUTION_ROLE_ARN}" = "None" ]; then
  echo "${TRUST_POLICY}" > /tmp/trust-policy.json

  aws iam create-role \
    --role-name "online-boutique-execution-role" \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --region "${AWS_REGION}" >/dev/null

  aws iam attach-role-policy \
    --role-name "online-boutique-execution-role" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
    --region "${AWS_REGION}" 2>/dev/null || true

  # Wait for role to propagate
  sleep 10

  EXECUTION_ROLE_ARN=$(aws iam get-role \
    --role-name "online-boutique-execution-role" \
    --query "Role.Arn" \
    --output text \
    --region "${AWS_REGION}")

  rm -f /tmp/trust-policy.json
fi

echo "  Execution Role: ${EXECUTION_ROLE_ARN}"

# --------------------------------------------
# 9. Register Task Definition
# --------------------------------------------
echo ""
echo "==> Step 9: Registering ECS task definition..."

TASK_DEF=$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "8192",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "redis-cart",
      "image": "redis:alpine",
      "essential": true,
      "portMappings": [
        {"containerPort": 6379, "protocol": "tcp"}
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "redis-cli ping || exit 1"],
        "interval": 10,
        "timeout": 5,
        "retries": 5
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "redis-cart"
        }
      }
    },
    {
      "name": "adservice",
      "image": "${ECR_URI}:adservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 9555, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "9555"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "adservice"
        }
      }
    },
    {
      "name": "cartservice",
      "image": "${ECR_URI}:cartservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 7070, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "REDIS_ADDR", "value": "localhost:6379"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "cartservice"
        }
      }
    },
    {
      "name": "checkoutservice",
      "image": "${ECR_URI}:checkoutservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 5050, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "5050"},
        {"name": "PRODUCT_CATALOG_SERVICE_ADDR", "value": "localhost:3550"},
        {"name": "SHIPPING_SERVICE_ADDR", "value": "localhost:50051"},
        {"name": "PAYMENT_SERVICE_ADDR", "value": "localhost:50052"},
        {"name": "EMAIL_SERVICE_ADDR", "value": "localhost:8081"},
        {"name": "CURRENCY_SERVICE_ADDR", "value": "localhost:7000"},
        {"name": "CART_SERVICE_ADDR", "value": "localhost:7070"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "checkoutservice"
        }
      }
    },
    {
      "name": "currencyservice",
      "image": "${ECR_URI}:currencyservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 7000, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "7000"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "currencyservice"
        }
      }
    },
    {
      "name": "emailservice",
      "image": "${ECR_URI}:emailservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 8081, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "8081"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "emailservice"
        }
      }
    },
    {
      "name": "frontend",
      "image": "${ECR_URI}:frontend-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 8080, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "8080"},
        {"name": "PRODUCT_CATALOG_SERVICE_ADDR", "value": "localhost:3550"},
        {"name": "CURRENCY_SERVICE_ADDR", "value": "localhost:7000"},
        {"name": "CART_SERVICE_ADDR", "value": "localhost:7070"},
        {"name": "RECOMMENDATION_SERVICE_ADDR", "value": "localhost:8082"},
        {"name": "SHIPPING_SERVICE_ADDR", "value": "localhost:50051"},
        {"name": "CHECKOUT_SERVICE_ADDR", "value": "localhost:5050"},
        {"name": "AD_SERVICE_ADDR", "value": "localhost:9555"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "frontend"
        }
      }
    },
    {
      "name": "paymentservice",
      "image": "${ECR_URI}:paymentservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 50052, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "50052"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "paymentservice"
        }
      }
    },
    {
      "name": "productcatalogservice",
      "image": "${ECR_URI}:productcatalogservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 3550, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "3550"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "productcatalogservice"
        }
      }
    },
    {
      "name": "recommendationservice",
      "image": "${ECR_URI}:recommendationservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 8082, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "8082"},
        {"name": "PRODUCT_CATALOG_SERVICE_ADDR", "value": "localhost:3550"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "recommendationservice"
        }
      }
    },
    {
      "name": "shippingservice",
      "image": "${ECR_URI}:shippingservice-${TAG}",
      "essential": true,
      "portMappings": [
        {"containerPort": 50051, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "PORT", "value": "50051"},
        {"name": "DISABLE_PROFILER", "value": "1"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/online-boutique",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "shippingservice"
        }
      }
    }
  ]
}
EOF
)

# Create CloudWatch log group
aws logs create-log-group \
  --log-group-name "/ecs/online-boutique" \
  --region "${AWS_REGION}" 2>/dev/null || true

# Write task def to temp file and register
echo "${TASK_DEF}" > /tmp/task-def.json
aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-def.json \
  --region "${AWS_REGION}" >/dev/null
rm -f /tmp/task-def.json

echo "  Task definition registered: ${TASK_FAMILY}"

# --------------------------------------------
# 10. Create ECS Service
# --------------------------------------------
echo ""
echo "==> Step 10: Creating ECS service..."

# Get task definition revision
TASK_DEF_ARN=$(aws ecs describe-task-definition \
  --task-definition "${TASK_FAMILY}" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text \
  --region "${AWS_REGION}")

# Build the subnets as a JSON array for the network configuration
SUBNET_ARRAY=$(echo "${SUBNET_IDS}" | tr '\t' '\n' | jq -R . | jq -s .)

aws ecs create-service \
  --cluster "${CLUSTER_NAME}" \
  --service-name "${SERVICE_NAME}" \
  --task-definition "${TASK_DEF_ARN}" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=${SUBNET_ARRAY},
    securityGroups=[\"${ECS_SG_ID}\"],
    assignPublicIp=ENABLED
  }" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=frontend,containerPort=8080" \
  --region "${AWS_REGION}" >/dev/null

echo "  Service created: ${SERVICE_NAME}"

# --------------------------------------------
# 11. Wait for service to stabilize
# --------------------------------------------
echo ""
echo "==> Step 11: Waiting for service to reach steady state..."
echo "  (This may take a few minutes)"

aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --region "${AWS_REGION}" 2>/dev/null || {
    echo "  WARNING: Timed out waiting for service to stabilize."
    echo "  Check the ECS console for service status."
  }

# --------------------------------------------
# Done
# --------------------------------------------
echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "  Application URL: http://${ALB_DNS}"
echo "  ECS Cluster:     ${CLUSTER_NAME}"
echo "  ECS Service:     ${SERVICE_NAME}"
echo "  Task Definition: ${TASK_FAMILY}"
echo "  Region:          ${AWS_REGION}"
echo ""
echo "  To check status:"
echo "    aws ecs describe-services --cluster ${CLUSTER_NAME} --services ${SERVICE_NAME} --region ${AWS_REGION}"
echo ""
echo "  To view logs:"
echo "    aws logs tail /ecs/online-boutique --follow --region ${AWS_REGION}"
echo ""
echo "  To scale:"
echo "    aws ecs update-service --cluster ${CLUSTER_NAME} --service ${SERVICE_NAME} --desired-count 3 --region ${AWS_REGION}"
echo ""
