# 인프라 (Docker)

> 실행 순서: **인프라 → 백엔드 → AI서버 → 목서버**

## 실행

```powershell
# Docker Desktop 먼저 실행

# 컨테이너 시작
docker compose up -d

# 종료
docker compose down
```

## Kafka 설정 변경 후 재생성

```powershell
docker compose up -d --force-recreate kafka
```

## 포트

| 서비스    | 포트        |
|-----------|-------------|
| Postgres  | 5432        |
| Kafka     | 9092 (외부) |
| Kafka UI  | 8081        |

---

## AWS 인프라 (Terraform)

AWS VPC/EC2 프로비저닝은 [terraform/](terraform/) 폴더 참고. (로컬 Grafana/ELK는 위 Docker 구성 유지)
