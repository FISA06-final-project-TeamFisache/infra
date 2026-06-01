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
