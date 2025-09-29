#!/bin/bash

# Script de Deploy BIA com Versionamento por Commit Hash
# Uso: ./deploy-com-ia.sh <cluster_name> <service_name>

set -e

# Validação de parâmetros
if [ $# -ne 2 ]; then
    echo "Uso: $0 <cluster_name> <service_name>"
    echo "Exemplo: $0 cluster-bia service-bia"
    exit 1
fi

CLUSTER_NAME=$1
SERVICE_NAME=$2
REGION="us-east-1"
ECR_REGISTRY="794038226274.dkr.ecr.us-east-1.amazonaws.com"
IMAGE_NAME="bia"

# Obter commit hash (7 dígitos)
COMMIT_HASH=$(git rev-parse --short=7 HEAD)
if [ -z "$COMMIT_HASH" ]; then
    echo "Erro: Não foi possível obter o commit hash. Certifique-se de estar em um repositório git."
    exit 1
fi

echo "🚀 Iniciando deploy com commit hash: $COMMIT_HASH"

# 1. Build da imagem Docker
echo "📦 Fazendo build da imagem Docker..."
docker build -t $IMAGE_NAME:$COMMIT_HASH .

# 2. Tag para ECR
echo "🏷️  Taggeando imagem para ECR..."
docker tag $IMAGE_NAME:$COMMIT_HASH $ECR_REGISTRY/$IMAGE_NAME:$COMMIT_HASH

# 3. Login no ECR
echo "🔐 Fazendo login no ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# 4. Push para ECR
echo "⬆️  Enviando imagem para ECR..."
docker push $ECR_REGISTRY/$IMAGE_NAME:$COMMIT_HASH

# 5. Obter task definition atual
echo "📋 Obtendo task definition atual..."
TASK_DEF_FAMILY=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text | cut -d'/' -f2 | cut -d':' -f1)

# 6. Criar nova task definition
echo "🔄 Criando nova task definition..."
aws ecs describe-task-definition --task-definition $TASK_DEF_FAMILY --query 'taskDefinition' > temp_task_def.json

# Atualizar imagem na task definition
jq --arg new_image "$ECR_REGISTRY/$IMAGE_NAME:$COMMIT_HASH" \
   'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy) | 
    .containerDefinitions[0].image = $new_image' \
   temp_task_def.json > new_task_def.json

# Registrar nova task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://new_task_def.json --query 'taskDefinition.taskDefinitionArn' --output text)

echo "✅ Nova task definition criada: $NEW_TASK_DEF_ARN"

# 7. Atualizar service
echo "🔄 Atualizando service..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN

# 8. Aguardar deployment
echo "⏳ Aguardando deployment completar..."
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME

# 9. Limpeza
rm -f temp_task_def.json new_task_def.json

echo "🎉 Deploy concluído com sucesso!"
echo "📊 Versão deployada: $COMMIT_HASH"
echo "🔗 Imagem: $ECR_REGISTRY/$IMAGE_NAME:$COMMIT_HASH"

# Verificar status final
echo "📈 Status final do service:"
aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,TaskDefinition:taskDefinition}' --output table
