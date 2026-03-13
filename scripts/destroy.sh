#!/usr/bin/env bash
# destroy.sh - Remove TODA a infraestrutura para parar de pagar
# Uso: ./scripts/destroy.sh [staging|prod]
# ATENCAO: isto apaga tudo, incluindo dados no S3 e PostgreSQL
set -euo pipefail

ENV=${1:-staging}
REGION="us-east-1"

echo "======================================================"
echo " FIAP X - DESTROY: ${ENV}"
echo " ATENCAO: Todos os dados serao perdidos!"
echo "======================================================"
read -rp " Digite 'destruir' para confirmar: " CONFIRM
[ "${CONFIRM}" = "destruir" ] || { echo "Cancelado."; exit 1; }

# Remove recursos K8s (libera Load Balancer antes do terraform destroy)
echo ""
echo "[1/3] Removendo recursos Kubernetes..."
kubectl delete -f k8s/10-ingress.yaml --ignore-not-found
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
helm uninstall rabbitmq -n fiapx 2>/dev/null || true
helm uninstall postgresql -n fiapx 2>/dev/null || true
kubectl delete namespace fiapx --ignore-not-found
kubectl delete namespace ingress-nginx --ignore-not-found

# Aguarda Load Balancer ser removido (evita erro no terraform)
echo "  Aguardando Load Balancers serem removidos (30s)..."
sleep 30

# Esvazia o bucket S3 antes do terraform destroy
echo ""
echo "[2/3] Esvaziando S3..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="fiapx-videos-${ENV}-${ACCOUNT_ID}"
aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true

# Terraform destroy
echo ""
echo "[3/3] Destruindo infraestrutura Terraform..."
cd terraform
terraform destroy -auto-approve \
  -var="environment=${ENV}" \
  -var="aws_region=${REGION}"

echo ""
echo "======================================================"
echo " Infraestrutura removida. Sem mais cobranças."
echo "======================================================"
