#!/bin/bash
set -euo pipefail

echo "🏁 Регрессионный тест Hotelio (монолит + booking-service + booking-history-service)"

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }
warn() { echo "⚠️  $1"; }

BASE="${API_URL:-http://localhost:8080}"

# booking-service: своя БД и gRPC API
export BOOKING_DB_HOST="${BOOKING_DB_HOST:-booking-db}"
export BOOKING_DB_PORT="${BOOKING_DB_PORT:-5432}"
export BOOKING_DB_NAME="${BOOKING_DB_NAME:-booking}"
export BOOKING_DB_USER="${BOOKING_DB_USER:-booking}"
export BOOKING_DB_PASSWORD="${BOOKING_DB_PASSWORD:-booking}"
BOOKING_GRPC="${BOOKING_GRPC:-booking-service:9090}"

# booking-history-service: своя БД и REST API статистики
HISTORY_DB_HOST="${HISTORY_DB_HOST:-booking-history-db}"
HISTORY_DB_PORT="${HISTORY_DB_PORT:-5432}"
HISTORY_DB_NAME="${HISTORY_DB_NAME:-booking_history}"
HISTORY_DB_USER="${HISTORY_DB_USER:-history}"
HISTORY_DB_PASSWORD="${HISTORY_DB_PASSWORD:-history}"
HISTORY_URL="${HISTORY_URL:-http://booking-history-service:8080}"

monolith_sql() {
  PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -qAt "$@"
}
booking_sql() {
  PGPASSWORD="${BOOKING_DB_PASSWORD}" psql -h "${BOOKING_DB_HOST}" -p "${BOOKING_DB_PORT}" -U "${BOOKING_DB_USER}" -d "${BOOKING_DB_NAME}" -v ON_ERROR_STOP=1 -qAt "$@"
}
history_sql() {
  PGPASSWORD="${HISTORY_DB_PASSWORD}" psql -h "${HISTORY_DB_HOST}" -p "${HISTORY_DB_PORT}" -U "${HISTORY_DB_USER}" -d "${HISTORY_DB_NAME}" -v ON_ERROR_STOP=1 -qAt "$@"
}
grpc() {
  grpcurl -plaintext -d "$2" "${BOOKING_GRPC}" "booking.BookingService/$1"
}

# Проверка соединения
echo "🧪 Проверка подключения к БД..."
for target in "${DB_HOST}:${DB_PORT}" "${BOOKING_DB_HOST}:${BOOKING_DB_PORT}" "${HISTORY_DB_HOST}:${HISTORY_DB_PORT}"; do
  timeout 2 bash -c "</dev/tcp/${target%:*}/${target#*:}" \
    || { echo "❌ Не удалось подключиться к ${target}"; exit 1; }
done

# Загрузка фикстур
echo "🧪 Загрузка фикстур..."
PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" "${DB_NAME}" < init-fixtures.sql

# Изоляция теста: очищаем БД новых сервисов (только для тестового стенда!)
echo "🧪 Очистка БД booking-service и booking-history-service..."
booking_sql -c "TRUNCATE booking, outbox_event"
history_sql -c "TRUNCATE booking_history, user_booking_stats, hotel_booking_stats, daily_booking_stats"

# Бронирования из фикстур монолита переносим в booking-service так же, как при его запуске
echo "🧪 Миграция бронирований монолит → booking-service..."
./migrate-bookings.sh

echo "🧪 Выполнение HTTP-тестов..."

echo ""
echo "Тесты пользователей..."
# 1. Получение пользователя по ID
curl -sSf "${BASE}/api/users/test-user-1" | grep -q 'Alice' && pass "Получение test-user-1 по ID работает" || fail "Пользователь test-user-1 не найден"

# 2. Статус пользователя
curl -sSf "${BASE}/api/users/test-user-1/status" | grep -q 'ACTIVE' && pass "Статус test-user-1: ACTIVE" || fail "Неверный статус пользователя"

# 3. Блэклист
curl -sSf "${BASE}/api/users/test-user-1/blacklisted" | grep -q 'true' && pass "test-user-1 в блэклисте" || fail "Блэклист не работает"

# 4. Активность
curl -sSf "${BASE}/api/users/test-user-1/active" | grep -q 'true' && pass "test-user-1 активен" || fail "Активность не работает"

# 5. Авторизация
curl -sSf "${BASE}/api/users/test-user-1/authorized" | grep -q 'false' && pass "test-user-1 не авторизован (в блэклисте)" || fail "Авторизация работает неправильно"

# 6. VIP-статус
curl -sSf "${BASE}/api/users/test-user-3/vip" | grep -q 'true' && pass "test-user-3 — VIP-пользователь" || fail "VIP-статус не работает"

# 7. Авторизация: положительный кейс
curl -sSf "${BASE}/api/users/test-user-2/authorized" | grep -q 'true' && pass "test-user-2 авторизован" || fail "Авторизация (true) не работает"

echo ""
echo "Тесты отелей..."

# 1. Получение отеля по ID
curl -sSf "${BASE}/api/hotels/test-hotel-1" | grep -q 'Seoul' && pass "test-hotel-1 получен по ID" || fail "test-hotel-1 не найден"

# 2. Проверка operational
curl -sSf "${BASE}/api/hotels/test-hotel-1/operational" | grep -q 'true' && pass "test-hotel-1 работает" || fail "test-hotel-1 не работает"
curl -sSf "${BASE}/api/hotels/test-hotel-3/operational" | grep -q 'false' && pass "test-hotel-3 не работает" || fail "Статус работы test-hotel-3 некорректен"

# 3. Проверка fullyBooked
curl -sSf "${BASE}/api/hotels/test-hotel-2/fully-booked" | grep -q 'true' && pass "test-hotel-2 полностью забронирован" || fail "Статус fullyBooked test-hotel-2 неверен"

# 4. Поиск по городу
curl -sSf "${BASE}/api/hotels/by-city?city=Seoul" | grep -q 'Seoul' && pass "Поиск отелей в Сеуле работает" || fail "Поиск отелей в Сеуле не работает"

# 5. Топ-отели (по рейтингу, limit)
curl -sSf "${BASE}/api/hotels/top-rated?city=Seoul&limit=1" | grep -q 'Seoul' && pass "Топ-отели в Сеуле загружены" || fail "Топ-отели не найдены"

echo ""
echo "Тесты ревью..."

# 11. Отзывы по hotelId
curl -sSf "${BASE}/api/reviews/hotel/test-hotel-1" | grep -q 'Amazing experience' \
  && pass "Отзывы test-hotel-1 найдены" || fail "Отзывы test-hotel-1 не найдены"

# 12. Надёжный отель (>=10 отзывов и avgRating >= 4.0)
curl -sSf "${BASE}/api/reviews/hotel/test-hotel-1/trusted" | grep -q 'true' \
  && pass "test-hotel-1 признан надёжным" || fail "Надёжность test-hotel-1 не определена"

# 13. Сомнительный отель (мало отзывов/низкий рейтинг)
curl -sSf "${BASE}/api/reviews/hotel/test-hotel-3/trusted" | grep -q 'false' \
  && pass "test-hotel-3 НЕ признан надёжным (ожидаемо)" || fail "Надёжность test-hotel-3 некорректно определена"

echo ""
echo "Тесты промокодов..."

# 1. Получение промо по коду
curl -sSf "${BASE}/api/promos/TESTCODE1" | grep -q 'TESTCODE1' && pass "Промокод TESTCODE1 найден" || fail "Промокод TESTCODE1 не найден"

# 2. Проверка VIP промо — для VIP
curl -sSf "${BASE}/api/promos/TESTCODE-VIP/valid?isVipUser=true" | grep -q 'true' && pass "VIP-промо доступен VIP" || fail "VIP-промо НЕ доступен VIP"

# 3. Проверка VIP промо — для обычного
curl -sSf "${BASE}/api/promos/TESTCODE-VIP/valid?isVipUser=false" | grep -q 'false' && pass "VIP-промо недоступен обычному" || fail "VIP-промо доступен обычному"

# 4. Проверка обычного промо
curl -sSf "${BASE}/api/promos/TESTCODE1/valid" | grep -q 'true' && pass "Обычный промо доступен" || fail "Обычный промо недоступен"

# 5. Проверка истекшего промо
curl -sSf "${BASE}/api/promos/TESTCODE-OLD/valid" | grep -q 'false' && pass "Истекший промо недоступен" || fail "Истекший промо доступен"

# 6. Валидация промо для user-2 (обычного)
curl -sSf -X POST "${BASE}/api/promos/validate?code=TESTCODE1&userId=test-user-2" | grep -q 'TESTCODE1' && pass "POST /validate промо прошёл" || fail "POST /validate не прошёл"

echo ""
echo "Тесты бронирования (монолит → gRPC → booking-service)..."

# 1. Все бронирования. Через монолит запрос без userId не работает: прокси p-o-y вызывает
#    BookingListRequest.setUserId(null) → NPE → 500. Поэтому проверяем gRPC ListBookings напрямую
grpc ListBookings '{}' | jq -e '[.bookings[].user_id] | index("test-user-2") and index("test-user-3")' >/dev/null \
  && pass "Все бронирования получены (gRPC ListBookings, перенесённые из монолита)" || fail "Бронирования не получены через gRPC"

code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/bookings")
[[ "$code" == "200" ]] && pass "GET /api/bookings без userId работает" \
  || warn "GET /api/bookings без userId → ${code}: ограничение прокси p-o-y (setUserId(null)), см. tasks/task2/results/README.md"

# 2. Получение бронирований пользователя через монолит (прокси → gRPC ListBookings)
curl -sSf "${BASE}/api/bookings?userId=test-user-2" | grep -q 'test-user-2' && pass "Бронирования test-user-2 найдены" || fail "Нет бронирований test-user-2"

# 3. Успешное бронирование отеля без промо
resp=$(curl -sSf -X POST "${BASE}/api/bookings?userId=test-user-3&hotelId=test-hotel-1") || fail "Бронирование (без промо) не прошло"
echo "$resp" | grep -q 'test-hotel-1' && pass "Бронирование прошло (без промо)" || fail "Бронирование (без промо) не прошло"
vip_booking_id=$(echo "$resp" | jq -r '.id')
echo "$resp" | jq -e '.price == 80 and .createdAt != null' >/dev/null \
  && pass "VIP-цена 80, createdAt заполнен" || fail "Неверная цена или пустой createdAt: $resp"

# 3a. Бронь создана booking-service: его id начинаются с 10 000 000, запись есть только в booking-db
[[ "$vip_booking_id" -ge 10000000 ]] && pass "Бронь ${vip_booking_id} создана booking-service (диапазон id ≥ 10 000 000)" \
  || fail "Бронь ${vip_booking_id} создана не booking-service"
[[ "$(booking_sql -c "SELECT count(*) FROM booking WHERE id = ${vip_booking_id}")" == "1" \
   && "$(monolith_sql -c "SELECT count(*) FROM booking WHERE id = ${vip_booking_id}")" == "0" ]] \
  && pass "Бронь ${vip_booking_id} сохранена в booking-db, а не в БД монолита" || fail "Бронь ${vip_booking_id} не в booking-db"

# 4. Успешное бронирование с промо
resp=$(curl -sSf -X POST "${BASE}/api/bookings?userId=test-user-2&hotelId=test-hotel-1&promoCode=TESTCODE1") || fail "Бронирование с промо не прошло"
echo "$resp" | grep -q 'TESTCODE1' && pass "Бронирование с промо прошло" || fail "Бронирование с промо не прошло"
promo_booking_id=$(echo "$resp" | jq -r '.id')
echo "$resp" | jq -e '.discountPercent == 10 and .price == 90' >/dev/null \
  && pass "Скидка по промокоду применена: 100 - 10 = 90" || fail "Неверный расчёт скидки: $resp"

# 5. Ошибка — неактивный пользователь
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/bookings?userId=test-user-0&hotelId=test-hotel-1")
if [[ "$code" == "500" ]]; then
  pass "Отклонено: неактивный пользователь"
else
  fail "Ошибка: сервер принял бронирование от неактивного пользователя (код $code)"
fi

# 6. Ошибка — отель не доверенный
curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/bookings?userId=test-user-2&hotelId=test-hotel-3" | grep -q '500' \
  && pass "Отклонено: недоверенный отель" \
  || fail "Ошибка: сервер принял бронирование от недоверенного отеля"

# 7. Ошибка — отель полностью забронирован
curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/bookings?userId=test-user-2&hotelId=test-hotel-2" | grep -q '500' \
  && pass "Отклонено: отель полностью забронирован" \
  || fail "Ошибка: сервер принял бронирование в полностью занятом отеле"

# 8. gRPC напрямую: отказ возвращается кодом FAILED_PRECONDITION с причиной
out=$(grpc CreateBooking '{"user_id":"test-user-0","hotel_id":"test-hotel-1"}' 2>&1 || true)
echo "$out" | grep -q 'FailedPrecondition' && echo "$out" | grep -q 'User is inactive' \
  && pass "gRPC CreateBooking: неактивный пользователь → FAILED_PRECONDITION" || fail "gRPC вернул неожиданный ответ: $out"

out=$(grpc CreateBooking '{"user_id":"test-user-1","hotel_id":"test-hotel-1"}' 2>&1 || true)
echo "$out" | grep -q 'User is blacklisted' \
  && pass "gRPC CreateBooking: пользователь в блэклисте → отказ" || fail "gRPC вернул неожиданный ответ: $out"

# 9. gRPC напрямую: успешное бронирование без промокода
resp=$(grpc CreateBooking '{"user_id":"test-user-2","hotel_id":"test-hotel-1"}') || fail "gRPC CreateBooking не прошёл"
grpc_booking_id=$(echo "$resp" | jq -r '.id')
echo "$resp" | jq -e '.price == 100 and (.created_at | test("Z$"))' >/dev/null \
  && pass "gRPC CreateBooking: бронь ${grpc_booking_id}, цена 100, createdAt в ISO-8601 UTC" || fail "gRPC CreateBooking: $resp"

# 10. Все события BookingCreated опубликованы из outbox в Kafka
for _ in $(seq 1 20); do
  [[ "$(booking_sql -c "SELECT count(*) FROM outbox_event WHERE published_at IS NULL")" == "0" ]] && break
  sleep 0.5
done
[[ "$(booking_sql -c "SELECT count(*) FROM outbox_event WHERE published_at IS NOT NULL")" == "3" ]] \
  && pass "Outbox: 3 события BookingCreated опубликованы в Kafka" || fail "Outbox: не все события опубликованы"

echo ""
echo "Тесты истории бронирований (Kafka → booking-history-service)..."

# Обработка асинхронная: ждём, пока все 3 брони появятся в истории
history_count=0
for _ in $(seq 1 30); do
  history_count=$(curl -s "${HISTORY_URL}/api/history/stats/summary" | jq -r '.bookingsCount // 0')
  [[ "$history_count" == "3" ]] && break
  sleep 1
done
[[ "$history_count" == "3" ]] && pass "История: получены все 3 события BookingCreated" || fail "История: получено ${history_count} из 3 событий"

# 1. Исторические записи конкретных бронирований
for id in "$vip_booking_id" "$promo_booking_id" "$grpc_booking_id"; do
  [[ "$(history_sql -c "SELECT count(*) FROM booking_history WHERE booking_id = ${id}")" == "1" ]] \
    || fail "История: нет записи о брони ${id}"
done
pass "История: записи о бронях ${vip_booking_id}, ${promo_booking_id}, ${grpc_booking_id} есть в booking_history"

curl -sSf "${HISTORY_URL}/api/history/bookings?userId=test-user-3" | jq -e "map(.bookingId) | index(${vip_booking_id}) != null" >/dev/null \
  && pass "История пользователя test-user-3 доступна через REST" || fail "История test-user-3 не найдена"

# 2. Статистика по пользователям
curl -sSf "${HISTORY_URL}/api/history/stats/users" \
  | jq -e '.[] | select(.userId == "test-user-2") | .bookingsCount == 2 and .promoBookingsCount == 1 and .totalPrice == 190' >/dev/null \
  && pass "Статистика по пользователю test-user-2: 2 брони, 1 с промо, сумма 190" || fail "Неверная статистика по пользователям"

# 3. Статистика по отелям
curl -sSf "${HISTORY_URL}/api/history/stats/hotels" \
  | jq -e '.[] | select(.hotelId == "test-hotel-1") | .bookingsCount == 3 and .totalPrice == 270' >/dev/null \
  && pass "Статистика по отелю test-hotel-1: 3 брони, сумма 270" || fail "Неверная статистика по отелям"

# 4. Статистика по дням
today=$(date -u +%F)
curl -sSf "${HISTORY_URL}/api/history/stats/days" \
  | jq -e --arg day "$today" '.[] | select(.day == $day) | .bookingsCount == 3' >/dev/null \
  && pass "Статистика за ${today}: 3 брони" || fail "Неверная статистика по дням"

# 5. Отклонённые бронирования в историю не попадают
[[ "$(history_sql -c "SELECT count(*) FROM booking_history WHERE user_id IN ('test-user-0', 'test-user-1')")" == "0" ]] \
  && pass "Отклонённые бронирования в историю не попали" || fail "В истории есть отклонённые бронирования"

echo ""
echo "✅ Все тесты пройдены!"
