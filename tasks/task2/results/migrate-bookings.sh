#!/bin/bash
# Перенос бронирований из БД монолита в БД booking-service.
#
# Брони в монолите только добавляются (update/delete в коде нет), поэтому перенос
# инкрементальный: копируются строки с id больше последнего уже перенесённого.
# Повторный запуск безопасен и догоняет новые записи. Собственные id booking-service
# начинаются с ID_RANGE_START, так что пересечений с id монолита нет.
set -euo pipefail

ID_RANGE_START=10000000

BOOKING_DB_HOST="${BOOKING_DB_HOST:-booking-db}"
BOOKING_DB_PORT="${BOOKING_DB_PORT:-5432}"
BOOKING_DB_NAME="${BOOKING_DB_NAME:-booking}"
BOOKING_DB_USER="${BOOKING_DB_USER:-booking}"
BOOKING_DB_PASSWORD="${BOOKING_DB_PASSWORD:-booking}"

monolith_sql() {
  PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 -qAt "$@"
}

booking_sql() {
  PGPASSWORD="${BOOKING_DB_PASSWORD}" psql -h "${BOOKING_DB_HOST}" -p "${BOOKING_DB_PORT}" -U "${BOOKING_DB_USER}" \
    -d "${BOOKING_DB_NAME}" -v ON_ERROR_STOP=1 -qAt "$@"
}

last_id=$(booking_sql -c "SELECT coalesce(max(id), 0) FROM booking WHERE id < ${ID_RANGE_START}")
echo "▶️  Перенос бронирований монолита с id > ${last_id}"

# created_at в монолите не заполняется (баг), а прокси монолита требует его для Instant.parse:
# пустые значения заменяем временем переноса
monolith_sql -c "\copy (SELECT id, user_id, hotel_id, nullif(promo_code, ''), coalesce(discount_percent, 0), price, coalesce(created_at, now()) FROM booking WHERE id > ${last_id} AND id < ${ID_RANGE_START} ORDER BY id) TO STDOUT WITH (FORMAT csv)" \
  | booking_sql -c "\copy booking (id, user_id, hotel_id, promo_code, discount_percent, price, created_at) FROM STDIN WITH (FORMAT csv)"

copied=$(booking_sql -c "SELECT count(*) FROM booking WHERE id > ${last_id} AND id < ${ID_RANGE_START}")
echo "    перенесено: ${copied}"

# Сверка: всё, что есть в монолите, должно быть в booking-db
source_count=$(monolith_sql -c "SELECT count(*) FROM booking WHERE id < ${ID_RANGE_START}")
target_count=$(booking_sql -c "SELECT count(*) FROM booking WHERE id < ${ID_RANGE_START}")
if [[ "${source_count}" == "${target_count}" ]]; then
  echo "✅ Сверка переноса: монолит ${source_count} = booking-db ${target_count}"
else
  echo "❌ Сверка переноса: монолит ${source_count} ≠ booking-db ${target_count}"
  exit 1
fi
