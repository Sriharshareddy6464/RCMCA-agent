output "api_url" {
  value = "https://${aws_lb.api.dns_name}"
}
output "evidence_bucket" {
  value = aws_s3_bucket.evidence.bucket
}
output "evidence_cdn_url" {
  value = "https://${aws_cloudfront_distribution.evidence.domain_name}"
}
output "ecr_api_repository" {
  value = aws_ecr_repository.app["api"].repository_url
}
output "ecr_osrm_repository" {
  value = aws_ecr_repository.app["osrm"].repository_url
}
output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}
