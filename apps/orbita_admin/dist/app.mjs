import { AdminApiError, createAdminApi } from './api.mjs';

const element = id => document.getElementById(id);
const panels = {
  active_orders: { body: element('orders'), count: element('orders-count'), empty: element('orders-empty') },
  history: { body: element('history'), count: element('history-count'), empty: element('history-empty') },
  queue: { body: element('queue'), count: element('queue-count'), empty: element('queue-empty') },
  drivers: { body: element('drivers'), count: element('drivers-count'), empty: element('drivers-empty') },
  audit: { body: element('audit'), count: element('audit-count'), empty: element('audit-empty') },
};
for (const panel of Object.values(panels)) panel.emptyText = panel.empty.textContent;
const states = {
  created: 'Ищем водителя',
  accepted: 'Водитель назначен',
  to_pickup: 'Едет к пассажиру',
  arrived: 'Прибыл',
  riding: 'В поездке',
  completed: 'Завершён',
  cancelled: 'Отменён',
  waiting: 'Свободен',
  offered: 'Получил предложение',
  busy: 'Выполняет заказ',
  updating: 'Ожидает обновления',
};
const reasons = { passenger: 'Отменил пассажир', search_timeout: 'Время поиска истекло' };
const timeFormat = new Intl.DateTimeFormat('ru-RU', {
  timeZone: 'Asia/Novosibirsk', dateStyle: 'short', timeStyle: 'short',
});
const status = element('status');
const signIn = element('sign-in');
const signInView = element('sign-in-view');
const dashboard = element('dashboard-view');
const signOut = element('sign-out');
const refresh = element('refresh');
const filters = element('filters');
const phoneForm = element('phone-form');
const phoneSubmit = element('create-phone');
const phoneResult = element('phone-result');

let api;
let token = null;
let request = null;
let visibleBoard = null;
let phoneIntent = null;
let restrictionIntent = null;

function message(text, error = false) {
  status.textContent = text;
  status.classList.toggle('error', error);
}

function textNode(tag, value, className = '') {
  const node = document.createElement(tag);
  node.textContent = value;
  if (className) node.className = className;
  return node;
}

function cell(value) {
  const node = document.createElement('td');
  if (value instanceof Node) node.append(value);
  else node.textContent = value;
  return node;
}

function row(...items) {
  const node = document.createElement('tr');
  node.append(...items.map(cell));
  return node;
}

function identifier(id) {
  if (!id) return '—';
  const node = textNode('abbr', id.slice(0, 8));
  node.title = id;
  return node;
}

function mark(value, pending = false) {
  return textNode('span', value, pending ? 'tag wait' : 'tag');
}

function time(value) {
  const node = textNode('time', timeFormat.format(new Date(value)));
  node.dateTime = value;
  return node;
}

function setRows(key, rows, truncated, filtered = false) {
  const panel = panels[key];
  panel.body.replaceChildren(...rows);
  panel.empty.hidden = rows.length > 0;
  panel.empty.textContent = filtered ? 'Совпадений в загруженном списке нет.' : panel.emptyText;
  panel.count.textContent = truncated
    ? filtered ? rows.length + ' из первых 50' : 'Первые 50'
    : String(rows.length);
}

function matches(query, ...fields) {
  return !query || fields.some(field => field?.toLocaleLowerCase('ru-RU').includes(query));
}

function driverAction(driver) {
  const button = textNode('button', driver.restricted ? 'Снять ограничение' : 'Ограничить',
    'button secondary table-action');
  button.type = 'button';
  button.dataset.driverId = driver.driver_id;
  button.addEventListener('click', () => changeRestriction(driver));
  return button;
}

function renderOperations(operations, query) {
  const available = operations !== null;
  const phoneAvailable = operations?.phone_orders_enabled === true;
  element('drivers-panel').hidden = !available;
  element('audit-panel').hidden = !available;
  element('phone-panel').hidden = !phoneAvailable;
  const unavailable = element('operations-unavailable');
  unavailable.hidden = available && phoneAvailable;
  unavailable.textContent = available
    ? 'Телефонные заказы пока недоступны.'
    : 'Управление водителями, журнал и телефонные заказы пока недоступны.';

  const focusedDriver = document.activeElement?.dataset?.driverId;
  const drivers = (operations?.drivers ?? [])
    .filter(driver => matches(query, driver.driver_id, driver.display_name, driver.active_order_id))
    .map(driver => row(
      driver.display_name || identifier(driver.driver_id),
      driver.online ? 'На линии' : 'Вне линии',
      identifier(driver.active_order_id),
      mark(driver.restricted ? 'Ограничены' : 'Разрешены', driver.restricted),
      driverAction(driver),
    ));
  setRows('drivers', drivers, operations?.truncated.drivers, !!query);
  if (focusedDriver) {
    Array.from(panels.drivers.body.querySelectorAll('button'))
      .find(button => button.dataset.driverId === focusedDriver)?.focus({ preventScroll: true });
  }

  const audit = (operations?.audit ?? []).map(event => row(
    time(event.created_at),
    event.action === 'phone_order' ? 'Создан телефонный заказ' :
      event.details.restricted ? 'Предложения ограничены' : 'Ограничение снято',
    identifier(event.target_id), identifier(event.actor_id),
  ));
  setRows('audit', audit, operations?.truncated.audit);
}

function renderBoard() {
  if (!visibleBoard) return;
  const { snapshot, operations } = visibleBoard;
  const query = element('query').value.trim().toLocaleLowerCase('ru-RU');
  const orderStatus = element('order-status').value;
  const filteredOrders = !!(query || orderStatus);
  const orderMatches = order => (!orderStatus || order.status === orderStatus) &&
    matches(query, order.id, order.pickup_address, order.destination_address, order.driver_id);
  const captured = Date.parse(snapshot.captured_at);
  setRows('active_orders', snapshot.active_orders.filter(orderMatches).map(order => {
    const route = textNode('div', order.pickup_address, 'route');
    route.append(textNode('small', 'Куда: ' + order.destination_address));
    const overdue = order.status === 'created' && Date.parse(order.expires_at) <= captured;
    return row(identifier(order.id), route,
      mark(overdue ? 'Поиск просрочен' : states[order.status], overdue), time(order.created_at));
  }), snapshot.truncated.active_orders, filteredOrders);
  setRows('queue', snapshot.queue
    .filter(driver => matches(query, driver.driver_id, driver.display_name, driver.order_id))
    .map(driver => row(
    driver.queue_rank ?? '—', driver.display_name || identifier(driver.driver_id),
    mark(states[driver.state], driver.state === 'updating'), identifier(driver.order_id),
  )), snapshot.truncated.queue, !!query);
  setRows('history', snapshot.history.filter(orderMatches).map(order => row(
    identifier(order.id), mark(states[order.status]), reasons[order.cancellation_reason] ?? '—',
    time(order.finished_at),
  )), snapshot.truncated.history, filteredOrders);
  renderOperations(operations, query);
  updateControls();
}

function show(board) {
  visibleBoard = board;
  renderBoard();
  element('updated-at').textContent = 'Данные на ' + timeFormat.format(new Date(board.snapshot.captured_at));
  element('data').hidden = false;
}

function clearData() {
  visibleBoard = null;
  element('data').hidden = true;
  for (const panel of Object.values(panels)) {
    panel.body.replaceChildren();
    panel.count.textContent = '';
  }
  phoneForm.reset();
  phoneResult.textContent = '';
  element('updated-at').textContent = 'Данные ещё не загружены';
}

function accessError(error) {
  return error instanceof AdminApiError && error.accessDenied;
}

async function loadBoard(accessToken, signal) {
  const [snapshot, operations] = await Promise.all([
    api.snapshot(accessToken, signal),
    api.operations(accessToken, signal).catch(error => {
      if (accessError(error)) throw error;
      return null;
    }),
  ]);
  return { snapshot, operations };
}

function updateControls() {
  const busy = request !== null;
  signIn.disabled = !api || busy;
  refresh.disabled = busy;
  phoneSubmit.disabled = busy || visibleBoard?.operations?.phone_orders_enabled !== true;
  for (const button of panels.drivers.body.querySelectorAll('button')) {
    button.setAttribute('aria-disabled', String(busy));
  }
}

function begin() {
  request = new AbortController();
  updateControls();
  return request;
}

function leave() {
  request?.abort();
  request = null;
  token = null;
  phoneIntent = null;
  restrictionIntent = null;
  clearData();
  filters.reset();
  dashboard.hidden = true;
  signOut.hidden = true;
  signInView.hidden = false;
  updateControls();
}

function expireAccess() {
  const expired = token;
  leave();
  if (expired) void api.signOut(expired).catch(() => {});
  message('Доступ к диспетчерской завершён. Войдите снова.', true);
  element('email').focus();
}

function finish(current) {
  if (request !== current) return;
  request = null;
  updateControls();
}

element('sign-in-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (request || !api || document.hidden) return;
  const current = begin();
  message('Проверяем доступ…');
  const password = element('password');
  const entered = password.value;
  password.value = '';
  let candidate;
  try {
    candidate = await api.signIn(element('email').value.trim(), entered, current.signal);
    const board = await loadBoard(candidate, current.signal);
    if (request !== current || document.hidden) return;
    token = candidate;
    candidate = null;
    signInView.hidden = true;
    signOut.hidden = false;
    dashboard.hidden = false;
    message('');
    show(board);
    element('dashboard-title').focus();
  } catch (error) {
    if (request === current) {
      message(accessError(error) ? 'Вход не выполнен. Проверьте данные и права администратора.' :
        'Не удалось загрузить диспетчерскую. Повторите вход позже.', true);
    }
  } finally {
    if (candidate) void api.signOut(candidate).catch(() => {});
    finish(current);
  }
});

async function update(keepMessage = false) {
  if (!token || request || document.hidden) return;
  const current = begin();
  try {
    const board = await loadBoard(token, current.signal);
    if (request !== current || document.hidden) return;
    if (!keepMessage) message('');
    show(board);
  } catch (error) {
    if (request !== current) return;
    clearData();
    if (accessError(error)) {
      expireAccess();
    } else {
      message('Данные временно недоступны. Повторите обновление.', true);
    }
  } finally {
    finish(current);
  }
}

function withRequestId(previous, value) {
  const fingerprint = JSON.stringify(value);
  return previous?.fingerprint === fingerprint
    ? previous : { fingerprint, requestId: crypto.randomUUID() };
}

async function mutate(run, onSuccess, onError) {
  if (!token || request || document.hidden || !visibleBoard?.operations) return;
  const current = begin();
  try {
    const result = await run(token, current.signal);
    if (request !== current || document.hidden) return;
    onSuccess(result);
  } catch (error) {
    if (request !== current || document.hidden) return;
    if (accessError(error)) expireAccess();
    else onError(error);
    return;
  } finally {
    finish(current);
  }
  void update(true);
}

function changeRestriction(driver) {
  if (!token || request || document.hidden || !visibleBoard?.operations) return;
  const restricted = !driver.restricted;
  if (restricted && !window.confirm(
    'Ограничить новые предложения для водителя «' + (driver.display_name || driver.driver_id) +
    '»? Водитель сможет завершить действующую поездку.',
  )) return;
  const value = { driverId: driver.driver_id, restricted };
  restrictionIntent = withRequestId(restrictionIntent, value);
  const payload = { ...value, requestId: restrictionIntent.requestId };
  void mutate(
    (accessToken, signal) => api.setDriverRestriction(accessToken, payload, signal),
    () => {
      restrictionIntent = null;
      message(restricted ? 'Новые предложения ограничены.' : 'Ограничение снято.');
    },
    error => message(error.status === 404 ? 'Управление доступом пока недоступно.' :
      'Сервер не подтвердил изменение. Обновите данные или повторите действие.', true),
  );
}

function phonePoint(prefix) {
  return {
    address: element(prefix + '-address').value.trim().replace(/\s+/gu, ' '),
    latitude: element(prefix + '-latitude').valueAsNumber,
    longitude: element(prefix + '-longitude').valueAsNumber,
  };
}

function describePhoneError(error) {
  if (error.kind === 'invalid-input') return 'Проверьте UUID пассажира и две разные точки.';
  if (error.status === 400) return 'Проверьте доступ пассажира и данные заказа.';
  if (error.status === 404) return 'Телефонные заказы пока недоступны.';
  if (error.status === 409) return 'Заказ конфликтует с действующей заявкой. Проверьте список заказов.';
  return 'Сервер не подтвердил заказ. Повтор с теми же данными проверит ту же заявку.';
}

phoneForm.addEventListener('submit', event => {
  event.preventDefault();
  if (!token || request || document.hidden || visibleBoard?.operations?.phone_orders_enabled !== true) return;
  const value = {
    passengerId: element('phone-passenger').value.trim().toLowerCase(),
    pickup: phonePoint('pickup'),
    destination: phonePoint('destination'),
  };
  phoneIntent = withRequestId(phoneIntent, value);
  const payload = { ...value, requestId: phoneIntent.requestId };
  phoneResult.classList.remove('error');
  phoneResult.textContent = 'Подтверждаем заказ…';
  void mutate(
    (accessToken, signal) => api.createPhoneOrder(accessToken, payload, signal),
    order => {
      phoneIntent = null;
      phoneForm.reset();
      phoneResult.textContent = 'Заказ ' + order.order_id.slice(0, 8) + ' · ' + states[order.status];
    },
    error => {
      phoneResult.classList.add('error');
      phoneResult.textContent = describePhoneError(error);
    },
  );
});

filters.addEventListener('submit', event => event.preventDefault());
filters.addEventListener('input', renderBoard);

signOut.addEventListener('click', async () => {
  if (!token) return;
  const previousToken = token;
  leave();
  message('');
  element('email').focus();
  try {
    await api.signOut(previousToken);
  } catch {
    if (!token && !request) message('Вы вышли из панели. Сервер не подтвердил завершение сеанса.', true);
  }
});
refresh.addEventListener('click', () => update());
window.setInterval(() => update(), 15_000);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (request) {
      const current = request;
      current.abort();
      finish(current);
    }
    clearData();
    message('');
  } else {
    void update();
  }
});
window.addEventListener('pagehide', leave);

try {
  if (!globalThis.isSecureContext) throw new Error('https');
  const response = await fetch('./config.json', {
    redirect: 'error', cache: 'no-store', credentials: 'omit', signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) throw new Error('config');
  const { publishableKey } = await response.json();
  api = createAdminApi(publishableKey);
  updateControls();
  message('');
} catch {
  message('Подключение диспетчерской ещё не настроено.', true);
}
