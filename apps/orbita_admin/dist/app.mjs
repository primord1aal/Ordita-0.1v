import { AdminApiError, createAdminApi } from './api.mjs';

const element = id => document.getElementById(id);
const panels = {
  active_orders: { body: element('orders'), count: element('orders-count'), empty: element('orders-empty') },
  history: { body: element('history'), count: element('history-count'), empty: element('history-empty') },
  queue: { body: element('queue'), count: element('queue-count'), empty: element('queue-empty') },
};
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

let api;
let token = null;
let request = null;

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

function setRows(key, rows, truncated) {
  const panel = panels[key];
  panel.body.replaceChildren(...rows);
  panel.empty.hidden = rows.length > 0;
  panel.count.textContent = truncated ? 'Первые 50' : String(rows.length);
}

function show(snapshot) {
  const captured = Date.parse(snapshot.captured_at);
  setRows('active_orders', snapshot.active_orders.map(order => {
    const route = textNode('div', order.pickup_address, 'route');
    route.append(textNode('small', 'Куда: ' + order.destination_address));
    const overdue = order.status === 'created' && Date.parse(order.expires_at) <= captured;
    return row(identifier(order.id), route,
      mark(overdue ? 'Поиск просрочен' : states[order.status], overdue), time(order.created_at));
  }), snapshot.truncated.active_orders);
  setRows('queue', snapshot.queue.map((driver, index) => row(
    index + 1, driver.display_name || identifier(driver.driver_id),
    mark(states[driver.state], driver.state === 'updating'), identifier(driver.order_id),
  )), snapshot.truncated.queue);
  setRows('history', snapshot.history.map(order => row(
    identifier(order.id), mark(states[order.status]), reasons[order.cancellation_reason] ?? '—',
    time(order.finished_at),
  )), snapshot.truncated.history);
  element('updated-at').textContent = 'Данные на ' + timeFormat.format(new Date(snapshot.captured_at));
  element('data').hidden = false;
}

function clearData() {
  element('data').hidden = true;
  for (const panel of Object.values(panels)) {
    panel.body.replaceChildren();
    panel.count.textContent = '';
  }
  element('updated-at').textContent = 'Данные ещё не загружены';
}

function accessError(error) {
  return error instanceof AdminApiError && error.accessDenied;
}

function leave() {
  request?.abort();
  request = null;
  token = null;
  clearData();
  dashboard.hidden = true;
  signOut.hidden = true;
  signInView.hidden = false;
  signIn.disabled = !api;
  refresh.disabled = false;
}

function finish(current) {
  if (request !== current) return;
  request = null;
  signIn.disabled = !api;
  refresh.disabled = false;
}

element('sign-in-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (request || !api || document.hidden) return;
  const current = request = new AbortController();
  signIn.disabled = true;
  message('Проверяем доступ…');
  const password = element('password');
  const entered = password.value;
  password.value = '';
  let candidate;
  try {
    candidate = await api.signIn(element('email').value.trim(), entered, current.signal);
    const snapshot = await api.snapshot(candidate, current.signal);
    if (request !== current || document.hidden) return;
    token = candidate;
    candidate = null;
    signInView.hidden = true;
    signOut.hidden = false;
    dashboard.hidden = false;
    message('');
    show(snapshot);
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

async function update() {
  if (!token || request || document.hidden) return;
  const current = request = new AbortController();
  refresh.disabled = true;
  try {
    const snapshot = await api.snapshot(token, current.signal);
    if (request !== current || document.hidden) return;
    message('');
    show(snapshot);
  } catch (error) {
    if (request !== current) return;
    clearData();
    if (accessError(error)) {
      const expired = token;
      leave();
      void api.signOut(expired).catch(() => {});
      message('Доступ к диспетчерской завершён. Войдите снова.', true);
      element('email').focus();
    } else {
      message('Данные временно недоступны. Повторите обновление.', true);
    }
  } finally {
    finish(current);
  }
}

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
refresh.addEventListener('click', update);
window.setInterval(update, 15_000);
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
  const response = await fetch('./config.json', {
    redirect: 'error', cache: 'no-store', credentials: 'omit', signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) throw new Error('config');
  const { publishableKey } = await response.json();
  api = createAdminApi(publishableKey);
  signIn.disabled = false;
  message('');
} catch {
  message('Подключение диспетчерской ещё не настроено.', true);
}
