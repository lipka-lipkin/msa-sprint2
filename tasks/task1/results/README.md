# Задание 1. Результаты

| Файл | Содержимое |
| :- | :- |
| [ADR-001-migration-to-microservices.md](ADR-001-migration-to-microservices.md) | ADR по шаблону: use cases, нефункциональные требования, ключевые проблемы (найденные и подтверждённые на стенде), целевая архитектура C4, выбор первого модуля (Booking) и план миграции по Strangler Fig, альтернативы, риски |
| [diagrams/](diagrams/) | C4-диаграммы: контекст, AS-IS, переходное состояние, TO-BE, sequence создания брони. Исходники в C4-PlantUML (`.puml`) и PNG |
| [test-log.txt](test-log.txt) | Проверка API и кодовой базы: регрессионные тесты `test/regress.sh` (29/29), анализ зависимостей и конфигурации в коде, API-запросы, подтверждающие проблемы из ADR |

Повторить проверку:

```bash
docker network create hotelio-net   # если сети ещё нет
cd tasks/task1
docker compose up -d --build
./run-checks.sh                     # перезапишет results/test-log.txt
```

`test/` в репозитории уже доработан под задание 2: там тесты для booking-service. Поэтому `run-checks.sh` берёт исходную версию тестов из первого коммита.
