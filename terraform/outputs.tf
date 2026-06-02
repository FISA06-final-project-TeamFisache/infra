output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_public_ip" {
  description = "private EC2가 외부로 나갈 때 쓰는 공인 IP(고정)"
  value       = aws_eip.nat.public_ip
}

output "instance_ids" {
  description = "인스턴스 ID (SSM 접속에 사용)"
  value       = { for k, i in aws_instance.this : k => i.id }
}

output "instance_private_ips" {
  value = { for k, i in aws_instance.this : k => i.private_ip }
}

output "ssm_connect_commands" {
  description = "SSM으로 셸 접속 (AWS CLI + Session Manager plugin 필요)"
  value       = { for k, i in aws_instance.this : k => "aws ssm start-session --target ${i.id}" }
}

output "batch_instance_id" {
  description = "배치 EC2 ID (enable_batch=true 일 때만)"
  value       = var.enable_batch ? aws_instance.batch[0].id : null
}

#############################################
# RDS (enable_rds=true 일 때만 값이 채워짐)
#############################################
output "rds_endpoint" {
  description = "RDS 접속 호스트 (private DNS, VPC 내부에서만 접근)"
  value       = var.enable_rds ? aws_db_instance.main[0].address : null
}

output "rds_port" {
  value = var.enable_rds ? aws_db_instance.main[0].port : null
}

output "rds_database" {
  value = var.enable_rds ? aws_db_instance.main[0].db_name : null
}

output "rds_username" {
  value = var.enable_rds ? aws_db_instance.main[0].username : null
}

output "rds_password" {
  description = "마스터 비밀번호 (확인: terraform output -raw rds_password)"
  value       = var.enable_rds ? random_password.rds[0].result : null
  sensitive   = true
}

output "rds_jdbc_url" {
  description = "Spring 등에서 쓸 JDBC URL (비밀번호는 별도)"
  value       = var.enable_rds ? "jdbc:postgresql://${aws_db_instance.main[0].address}:${aws_db_instance.main[0].port}/${aws_db_instance.main[0].db_name}" : null
}
