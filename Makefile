IMAGE         ?= eccube
PHP           ?= 8.3-apache
ECCUBE        ?= 4.3.1-p1
ECCUBE_SHA256 ?= 5783ae3598a902a4bce1d59ea8592281f02f5306d253944dfb45c8cb58680ab4
TAG           ?= $(ECCUBE)

CONTAINER     ?= eccube
PORT          ?= 8080

BUILD_ARGS = --build-arg PHP=$(PHP) \
             --build-arg ECCUBE=$(ECCUBE) \
             --build-arg ECCUBE_SHA256=$(ECCUBE_SHA256)

.DEFAULT_GOAL := help
.PHONY: help build rebuild run stop logs shell size clean

help: ## このヘルプを表示
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  変数: IMAGE=$(IMAGE) TAG=$(TAG) PHP=$(PHP) ECCUBE=$(ECCUBE) PORT=$(PORT)"

build: ## イメージをビルド (IMAGE:TAG と IMAGE:latest)
	docker build $(BUILD_ARGS) -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

rebuild: ## キャッシュを使わずにビルド (ベースイメージも再取得)
	docker build --pull --no-cache $(BUILD_ARGS) -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

run: stop ## コンテナを起動 (http://localhost:PORT/)
	docker run -d --name $(CONTAINER) -p $(PORT):80 $(IMAGE):$(TAG)
	@echo "http://localhost:$(PORT)/"

stop: ## コンテナを停止・削除
	-@docker rm -f $(CONTAINER) >/dev/null 2>&1 || true

logs: ## コンテナのログを表示
	docker logs -f $(CONTAINER)

shell: ## 起動中のコンテナに入る
	docker exec -it $(CONTAINER) bash

size: ## イメージサイズとレイヤー内訳を表示
	@docker images $(IMAGE):$(TAG) --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
	@docker history $(IMAGE):$(TAG) --format '{{.Size}}\t{{.CreatedBy}}' | awk -F'\t' '$$1 != "0B"' | cut -c1-100

clean: stop ## コンテナとイメージを削除
	-docker rmi $(IMAGE):$(TAG) $(IMAGE):latest
