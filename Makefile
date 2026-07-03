.PHONY: up down reload logs ps

up:
	docker compose up -d

down:
	docker compose down

reload:
	docker compose up -d --force-recreate

logs:
	docker compose logs -f --tail=100

ps:
	docker compose ps

smoke:
	bash scripts/smoke.sh

names:
	@curl -s 'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep claude_code || echo "no claude_code metrics yet"
