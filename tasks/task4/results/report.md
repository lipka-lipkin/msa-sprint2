# Задание 4. Автоматизация развёртывания и тестирования — отчёт

Сервис `booking-service` собирается в Docker-образ, разворачивается Helm-чартом в Minikube и доставляется пайплайном `.gitlab-ci.yml`. Пайплайн запускается локально через gitlab-ci-local.

Проверено на macOS (arm64): Docker 27.4, Minikube 1.39 (Kubernetes 1.37, драйвер docker), Helm 4.3, gitlab-ci-local 4.76.

## 1. Сервис и Docker-образ

Мок заменён реализацией на Go **на основе предложенного сервиса**, как разрешает README задания. Java-сервис бронирования из задания 2 сюда не подходит. Без Postgres, Kafka и монолита он не стартует, и smoke-тест `docker run → /ping` в CI потерял бы смысл. Здесь же предмет задания — доставка: образ, чарт, пайплайн и service discovery.

| Эндпоинт | Назначение |
| :- | :- |
| `GET /ping` | `pong`. Liveness- и readiness-пробы Kubernetes, smoke-тест в CI, DNS-проверка |
| `GET /health` | Healthcheck процесса: `{"status":"UP"}`. Используется в `HEALTHCHECK` Dockerfile |
| `GET /ready` | Готовность: `200 READY` после старта, `503 NOT_READY` до старта и во время graceful shutdown. Используется в `startupProbe` |
| `GET /info` | Версия, окружение (`APP_ENV`), имя пода и состояние фича-флагов |
| `GET /feature` | Есть **только при `ENABLE_FEATURE_X=true`**, иначе 404 |

**Фича-флаг.** `ENABLE_FEATURE_X=true` включает маршрут `/feature`. Каждый ответ содержит заголовок `X-Feature-X: enabled|disabled`, а `/info` показывает флаг. Так поведение видно и снаружи, и в маршрутизации (заголовок пригодится для Istio в задании 5).

**Graceful shutdown.** По SIGTERM сервис сначала становится not ready, затем выжидает `SHUTDOWN_DELAY`, пока Kubernetes уберёт под из Service, и только после этого завершает текущие запросы.

**Dockerfile** ([booking-service/Dockerfile](../booking-service/Dockerfile)) — многоэтапный:
- `base` — исходники и модули;
- `test` — `go test -v ./...`, отдельная стадия для unit-тестов в CI (`docker build --target test`);
- `build` — статический бинарник (`CGO_ENABLED=0`);
- итоговый образ — `alpine:3.20`, только бинарник, пользователь `10001`, `HEALTHCHECK` по `/health`. **Размер — 20,2 МБ.**

**Unit-тесты** ([app_test.go](../booking-service/app_test.go)) — 7 тестов:
- `/ping`, `/health`;
- жизненный цикл `/ready`;
- `/feature` с флагом и без;
- `/info`;
- чтение конфигурации из окружения.

## 2. Helm-чарт

[helm/booking-service](../helm/booking-service): Deployment и Service типа `ClusterIP` (порт 80 → targetPort 8080).

| Ключ `values.yaml` | Что задаёт |
| :- | :- |
| `replicaCount` | Число реплик |
| `image.name`, `image.tag`, `image.pullPolicy` | Образ. `Never`, потому что образ загружается в Minikube через `minikube image load` |
| `featureFlags.ENABLE_FEATURE_X` | Фича-флаг, превращается в переменную окружения `ENABLE_FEATURE_X` |
| `env[]` | Дополнительные переменные окружения: список `{name, value}` |
| `resources.requests/limits` | CPU и память |
| `livenessProbe`, `readinessProbe` | Обе пробы по `/ping`, как требует задание |
| `startupProbe` | По `/ready`. Пока сервис не готов, liveness и readiness не проверяются |
| `strategy` | RollingUpdate, `maxSurge: 1`, `maxUnavailable: 0` — обновление без простоя |
| `podAnnotations` | Сюда CI кладёт id образа (см. ниже) |
| `securityContext` | non-root, `readOnlyRootFilesystem`, без повышения привилегий |

Два окружения:

| | [values-staging.yaml](values-staging.yaml) | [values-prod.yaml](values-prod.yaml) |
| :- | :- | :- |
| Реплики | 1 | 3 |
| `ENABLE_FEATURE_X` | `true` — фичу проверяем на staging | `false` — до решения бизнеса |
| Ресурсы (requests / limits) | 50m, 32Mi / 200m, 64Mi | 100m, 64Mi / 500m, 128Mi |
| `APP_ENV`, `APP_VERSION` | `staging`, `1.0.0-staging` | `prod`, `1.0.0` |
| `SHUTDOWN_DELAY` | 2s | 5s |
| readinessProbe `failureThreshold` | 3 | 2 — быстрее выводим больной под из балансировки |

Чарт проходит `helm lint` для обоих файлов, рендер принимает API-сервер (`kubectl apply --dry-run=server`).

## 3. CI/CD-пайплайн

[.gitlab-ci.yml](.gitlab-ci.yml). Джобы без `image` выполняются shell-executor'ом gitlab-ci-local на хосте.

| Стадия | Джоб | Что делает |
| :- | :- | :- |
| build | `build` | `docker build -t booking-service:latest booking-service` |
| test | `unit-test` | Отдельный шаг для unit-тестов: `docker build --target test` с `--no-cache-filter test`, чтобы тесты прогонялись всегда, а не брались из кэша |
| test | `test` | [scripts/smoke-test.sh](../scripts/smoke-test.sh): `docker run` → проверка `/ping`, `/health`, `/ready`, `/feature` (404 без флага, 200 с флагом) → `docker rm`. Контейнер удаляется и при ошибке (`trap`) |
| deploy | `deploy` | `minikube image load`, затем `helm upgrade --install -f values-$DEPLOY_ENV.yaml --wait`, `kubectl rollout status` |
| tag | `tag` | `git tag -a booking-service-<env>-<UTC timestamp>`, тот же тег на образе |

Особенности:
- **Перекат при неизменном теге.** Тег `latest` не меняется, поэтому `helm upgrade` сам по себе поды не перекатит. CI передаёт в `podAnnotations.imageId` короткий id собранного образа: новый образ — новая аннотация — rolling update.
- **Выбор окружения.** По умолчанию staging. Prod: `npx gitlab-ci-local --variable DEPLOY_ENV=prod deploy` (лог — [deploy-prod-log.txt](deploy-prod-log.txt)).
- **Переход на боевую схему:**
  - убрать строку `minikube image load`;
  - пушить образ в registry с неизменяемым тегом (например, `$CI_COMMIT_SHORT_SHA`);
  - выставить `image.pullPolicy: IfNotPresent`.
- **Команды запуска:**
  - `npx gitlab-ci-local` — весь пайплайн, включая `unit-test`: все 5 джобов `PASS`, 23 с ([build-log.txt](build-log.txt));
  - `npx gitlab-ci-local build test deploy tag` — команда из задания, тоже проходит ([build-log-task-command.txt](build-log-task-command.txt)). Но позиционные аргументы gitlab-ci-local — это имена джобов, поэтому **`unit-test` в ней не запускается**. Чтобы его включить: `npx gitlab-ci-local build unit-test test deploy tag`.

## 4. Service Discovery через DNS

Service `booking-service` типа ClusterIP получает в CoreDNS запись `booking-service.default.svc.cluster.local` → ClusterIP. В `resolv.conf` пода прописан search-домен `default.svc.cluster.local`, поэтому из того же namespace достаточно короткого имени `booking-service`. kube-proxy балансирует ClusterIP между endpoints — в prod это 3 пода (см. `kubectl get endpoints` в [kubectl-get-pods-services.txt](kubectl-get-pods-services.txt)).

[check-dns.sh](../check-dns.sh) запускает одноразовый под `busybox` и в нём:
1. Делает `nslookup booking-service` и сверяет полученный адрес с ClusterIP Service.
2. Делает `wget http://booking-service/ping` и ожидает `pong`.

Вывод в формате задания: `[INFO] … DNS Response: pong`, `[PASS] DNS test succeeded`. При ошибке — `[FAIL]` и ненулевой код выхода.

Найденная мелочь: `kubectl run --rm -i` иногда печатает вывод пода дважды (attach плюс fallback на логи). Скрипт берёт первые совпадения, поэтому результат стабилен.

## Результаты

Итоговое состояние кластера — **prod**: 3 реплики, фича X выключена. Состояние staging (1 реплика, фича включена) сохранено в [staging-check.txt](staging-check.txt).

| Файл | Содержимое |
| :- | :- |
| [values-staging.yaml](values-staging.yaml), [values-prod.yaml](values-prod.yaml) | Values окружений (копии из чарта) |
| [.gitlab-ci.yml](.gitlab-ci.yml) | Пайплайн (копия) |
| [build-log.txt](build-log.txt) | Лог успешного прогона всего пайплайна: build → unit-test → test → deploy → tag |
| [build-log-task-command.txt](build-log-task-command.txt) | Лог команды из задания `gitlab-ci-local build test deploy tag` |
| [deploy-prod-log.txt](deploy-prod-log.txt) | Деплой prod тем же джобом `deploy` |
| [screenshot-curl-ping.png](screenshot-curl-ping.png) ([txt](curl-ping.txt)) | `curl` на `/ping` через `kubectl port-forward`, плюс `/feature` → 404 и `/info` в prod |
| [screenshot-check-dns.png](screenshot-check-dns.png) ([txt](check-dns.txt)) | `./check-dns.sh` |
| [screenshot-check-status.png](screenshot-check-status.png) ([txt](check-status.txt)) | `./check-status` |
| [kubectl-get-pods-services.txt](kubectl-get-pods-services.txt) | `kubectl get pods`, `get services`, deployment, helm release, endpoints |
| [docker-image-ls_minikube-image-list.txt](docker-image-ls_minikube-image-list.txt) | `docker image ls` и `minikube image list` |
| [staging-check.txt](staging-check.txt) | Staging: `/ping` с `X-Feature-X: enabled`, `/feature`, `/info` |

Скриншоты — не снимки окна терминала, а рендер реального вывода команд в PNG (headless Chrome). Это указано в заголовке каждого изображения, а исходный текст лежит рядом в `.txt`.

## Прочие изменения

- **Исходный Dockerfile не собирался.** Он копировал `check-dns.sh`, которого нет в контексте сборки `booking-service/`. Скрипт проверки DNS запускается с хоста через `kubectl`, а не из образа, поэтому в новом Dockerfile этого копирования нет.
- **`check-status`** — симлинк на `check-status.sh`, потому что задание ссылается на `./check-status`. В конце вывода добавлен пробел перед «✅ Reachable».
- **`.gitignore`** — добавлен `node_modules/`. gitlab-ci-local ставится локально через `package.json` задания: `npm install && npx gitlab-ci-local`.
- **Git-теги.** Пайплайн создал в локальном репозитории теги `booking-service-staging-20261026-153016`, `-153143` и `-153650`. В удалённый репозиторий они не пушились. Код заданий на момент прогона ещё не был закоммичен, поэтому теги указывают на начальный коммит. Перед `git push --tags` их нужно удалить (`git tag -d …`) или пересоздать после коммита.
