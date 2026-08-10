.PHONY: compose-up compose-down build up plan down fmt validate lint load-test

TF_DIR := infra/terraform
CHART_DIR := infra/helm/mural
INGRESS_HOST := mural.localtest.me

## docker-compose (só para entender a app)
compose-up:
	docker compose up --build -d

compose-down:
	docker compose down -v

## build local das imagens da app (o terraform também faz isso; útil isolado)
build:
	docker build -t mural-api:local -f app/docker/api.Dockerfile app/api
	docker build -t mural-web:local -f app/docker/web.Dockerfile app/web

## ciclo Terraform: cluster kind + Traefik + chart, do zero até responder no navegador
up:
	cd $(TF_DIR) && terraform init -upgrade=false && terraform apply -auto-approve

plan:
	cd $(TF_DIR) && terraform plan

down:
	cd $(TF_DIR) && terraform destroy -auto-approve

fmt:
	cd $(TF_DIR) && terraform fmt

validate:
	cd $(TF_DIR) && terraform validate

lint:
	helm lint $(CHART_DIR) --set postgres.password=lint-only

## teste de carga (bônus): sobe a API sob 80 VUs por 3min via k6.
## acompanhe o HPA em outro terminal com: kubectl get hpa -n mural -w
load-test:
	docker run --rm --network host \
		-e INGRESS_HOST=$(INGRESS_HOST) \
		-v $(CURDIR)/scripts/load-test.js:/load-test.js:ro \
		grafana/k6 run /load-test.js
