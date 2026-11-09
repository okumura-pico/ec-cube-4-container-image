IMAGE         ?= eccube
PHP           ?= 8.3-apache
ECCUBE        ?= 4.3.1-p1
ECCUBE_SHA256 ?= 5783ae3598a902a4bce1d59ea8592281f02f5306d253944dfb45c8cb58680ab4
TAG           ?= $(ECCUBE)

CONTAINER     ?= eccube
PORT          ?= 8080
ENV_FILE      ?= eccube.env

BUILD_ARGS = --build-arg PHP=$(PHP) \
             --build-arg ECCUBE=$(ECCUBE) \
             --build-arg ECCUBE_SHA256=$(ECCUBE_SHA256)

.DEFAULT_GOAL := help
.PHONY: help build rebuild run stop logs shell size clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: IMAGE=$(IMAGE) TAG=$(TAG) PHP=$(PHP) ECCUBE=$(ECCUBE) PORT=$(PORT)"

build: ## Build the image (tagged IMAGE:TAG and IMAGE:latest)
	docker build $(BUILD_ARGS) -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

rebuild: ## Build without cache (also pulls the base image)
	docker build --pull --no-cache $(BUILD_ARGS) -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

run: stop ## Start the container with variables from ENV_FILE (http://localhost:PORT/)
	@test -f $(ENV_FILE) || { echo "$(ENV_FILE) not found (copy eccube.env.sample to create it)"; exit 1; }
	docker run -d --name $(CONTAINER) -p $(PORT):80 --env-file $(ENV_FILE) $(IMAGE):$(TAG)
	@echo "http://localhost:$(PORT)/"

stop: ## Stop and remove the container
	-@docker rm -f $(CONTAINER) >/dev/null 2>&1 || true

logs: ## Follow container logs
	docker logs -f $(CONTAINER)

shell: ## Open a shell in the running container
	docker exec -it $(CONTAINER) bash

size: ## Show image size and layer breakdown
	@docker images $(IMAGE):$(TAG) --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
	@docker history $(IMAGE):$(TAG) --format '{{.Size}}\t{{.CreatedBy}}' | awk -F'\t' '$$1 != "0B"' | cut -c1-100

clean: stop ## Remove the container and images
	-docker rmi $(IMAGE):$(TAG) $(IMAGE):latest
