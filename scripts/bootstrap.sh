#!/usr/bin/env bash
# bootstrap.sh - Provisiona toda a infraestrutura FIAP X do zero
# Uso: ./scripts/bootstrap.sh [staging|prod]
# Pre-requisitos: aws cli, terraform, kubectl, helm
set -euo pipefail

ENV=${1:-staging}
REGION="us-east-1"
CLUSTER_NAME="fiapx-${ENV}"

echo "======================================================"
echo " FIAP X - Bootstrap de infraestrutura: ${ENV}"
echo "======================================================"

# 1. Cria bucket S3 para estado do Terraform (idempotente)
echo ""
echo "[1/6] Criando bucket de estado do Terraform..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_BUCKET="fiapx-tfstate-${ACCOUNT_ID}"

if ! aws s3api head-bucket --bucket "${TF_BUCKET}" 2>/dev/null; then
  aws s3api create-bucket --bucket "${TF_BUCKET}" --region "${REGION}"
  aws s3api put-bucket-versioning --bucket "${TF_BUCKET}" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "${TF_BUCKET}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  echo "  Bucket criado: ${TF_BUCKET}"
else
  echo "  Bucket ja existe: ${TF_BUCKET}"
fi

# Atualiza o backend no main.tf com o nome correto do bucket
sed -i "s/fiapx-tfstate/${TF_BUCKET}/g" terraform/main.tf

# 2. Terraform - provisiona VPC, EKS, S3, ECR
echo ""
echo "[2/6] Executando Terraform..."
cd terraform
terraform init -reconfigure \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="region=${REGION}"

terraform apply -auto-approve \
  -var="environment=${ENV}" \
  -var="aws_region=${REGION}"

# Captura outputs
S3_BUCKET=$(terraform output -raw s3_bucket_name)
POD_ROLE_ARN=$(terraform output -raw pod_s3_role_arn)
cd ..

echo "  S3 bucket: ${S3_BUCKET}"
echo "  Pod IAM role: ${POD_ROLE_ARN}"

# 3. Configura kubectl
echo ""
echo "[3/6] Configurando kubectl..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}"
kubectl cluster-info

# 4. Instala dependencias via Helm (todos open-source)
echo ""
echo "[4/6] Instalando dependencias via Helm..."

# Adiciona repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Namespace
kubectl apply -f k8s/00-namespace.yaml

# Secrets (usuario precisa preencher antes)
echo ""
echo "  ATENCAO: Edite k8s/02-secrets.yaml com suas senhas antes de continuar."
echo "  Pressione ENTER quando estiver pronto..."
read -r

kubectl apply -f k8s/02-secrets.yaml

# PostgreSQL (1 instancia, 3 databases)
echo "  Instalando PostgreSQL..."
helm upgrade --install postgresql bitnami/postgresql \
  --namespace fiapx \
  --values k8s/04-postgresql-values.yaml \
  --wait --timeout 5m

# RabbitMQ
echo "  Instalando RabbitMQ..."
helm upgrade --install rabbitmq bitnami/rabbitmq \
  --namespace fiapx \
  --values k8s/03-rabbitmq-values.yaml \
  --wait --timeout 5m

# ingress-nginx (NLB da AWS - unico ponto de entrada)
echo "  Instalando ingress-nginx..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values k8s/05-ingress-nginx-values.yaml \
  --wait --timeout 5m

# metrics-server (necessario para HPA funcionar)
helm upgrade --install metrics-server bitnami/metrics-server \
  --namespace kube-system \
  --set apiService.create=true \
  --set extraArgs[0]="--kubelet-insecure-tls" \
  --wait --timeout 3m

# 5. Substitui placeholders nos manifests K8s
echo ""
echo "[5/6] Aplicando manifests Kubernetes..."

# Substitui REPLACE_AWS_ACCOUNT e REPLACE_POD_S3_ROLE_ARN
find k8s -name "*.yaml" -exec sed -i \
  "s|REPLACE_AWS_ACCOUNT|${ACCOUNT_ID}|g; s|REPLACE_POD_S3_ROLE_ARN|${POD_ROLE_ARN}|g" {} \;

# Atualiza secret com valores reais do terraform
kubectl -n fiapx patch secret fiapx-secrets \
  --type=merge \
  -p "{\"stringData\":{\"S3_BUCKET_NAME\":\"${S3_BUCKET}\",\"AWS_REGION\":\"${REGION}\"}}"

kubectl apply -f k8s/01-configmap.yaml
kubectl apply -f k8s/06-auth-service.yaml
kubectl apply -f k8s/07-upload-service.yaml
kubectl apply -f k8s/08-processor-service.yaml
kubectl apply -f k8s/09-frontend.yaml
kubectl apply -f k8s/10-ingress.yaml

# 6. Aguarda e exibe URL de acesso
echo ""
echo "[6/6] Aguardando NLB ficar disponivel..."
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=3m

NLB_HOST=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pendente")

echo ""
echo "======================================================"
echo " Deploy concluido!"
echo "======================================================"
echo " URL de acesso: http://${NLB_HOST}"
echo " S3 Bucket:     ${S3_BUCKET}"
echo " Cluster:       ${CLUSTER_NAME}"
echo ""
echo " Proximos passos:"
echo "   - Configure seu DNS para apontar para: ${NLB_HOST}"
echo "   - Adicione TLS via cert-manager (opcional)"
echo "======================================================"
