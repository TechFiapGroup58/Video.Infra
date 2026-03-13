output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "s3_bucket_name" {
  value = aws_s3_bucket.videos.bucket
}

output "ecr_repositories" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "pod_s3_role_arn" {
  value = aws_iam_role.pod_s3.arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
