(() => {
  'use strict';

  const $ = id => document.getElementById(id);
  const show = (id, yes) => $(id).classList.toggle('hidden', !yes);
  const same = (a, b) => a != null && b != null && String(a) === String(b);
  const tripStatuses = new Set(['accepted', 'arrived', 'on_trip']);
  const activeStatuses = new Set(['new', 'offered', ...tripStatuses]);
  const labels = {
    new: 'Ожидает свободного водителя', offered: 'Предложен водителю',
    accepted: 'Водитель выехал', arrived: 'Водитель на месте',
    on_trip: 'В пути', completed: 'Завершён', cancelled: 'Отменён',
  };
  const driverLabels = {
    offered: 'Получает предложение', accepted: 'Едет к пассажиру',
    arrived: 'Прибыл к пассажиру', on_trip: 'Везёт пассажира',
  };
  const title = document.title;
  let sb = null, account = null, role = null, driver = null;
  let currentOrders = [], adminDrivers = [];
  let busy = false, updatePromise = null, interval = null, epoch = 0;
  let lastSync = null, currentOffer = null, displayedOfferKey = null;
  let offerTimer = null, ringTimer = null, audio = null, soundEnabled = false;
  let notificationsEnabled = false, notificationRegistration = null;
  let notificationHandle = null, notificationTag = null, lastDriverOrder = null;
  const soundedOffers = new Set(), soundNodes = new Set();
  let map = null, pickupCoords = null, destinationCoords = null;
  let pickupMark = null, destinationMark = null;

  function pref(name, value) {
    try {
      if (value === undefined) return localStorage.getItem('orbita-v03-' + name);
      localStorage.setItem('orbita-v03-' + name, value);
    } catch (_) { /* Preferences must not prevent answering a trip. */ }
    return null;
  }

  function text(tag, content, cls = '') {
    const el = document.createElement(tag);
    el.textContent = String(content ?? '');
    if (cls) el.className = cls;
    return el;
  }

  function banner(message, kind = '') {
    $('notice').textContent = message;
    $('notice').className = 'banner' + (kind ? ' ' + kind : '');
  }

  function badge(label, kind = '') {
    return text('span', label, 'badge' + (kind ? ' ' + kind : ''));
  }

  function errorText(error) {
    return String(error?.message || error || 'Неизвестная ошибка');
  }

  function setBusy(value) {
    busy = value;
    document.querySelectorAll('[data-mutation]').forEach(el => { el.disabled = value; });
    $('loginForm').querySelector('button').disabled = value;
    if (account && (role === 'passenger' || role === 'admin')) {
      $('orderForm').querySelector('button').disabled = value || currentOrders.some(order =>
        same(order.passenger_id, account.id) && activeStatuses.has(order.status));
    }
    setShiftButtons();
    refreshCountdown();
  }

  function mutationButton(label, action, cls = 'secondary') {
    const button = text('button', label, 'btn small ' + cls);
    button.type = 'button';
    button.dataset.mutation = 'true';
    button.disabled = busy;
    button.addEventListener('click', () => {
      const container = button.parentElement;
      container?.querySelector(':scope > .action-error')?.remove();
      runAction(action, error => {
        if (!container?.isConnected) return;
        const message = text('p', errorText(error), 'action-error');
        message.setAttribute('role', 'alert'); container.append(message);
      });
    });
    return button;
  }

  async function rpc(name, args) {
    if (!sb || !account) throw new Error('Сначала войдите в приложение.');
    const { data, error } = await sb.rpc(name, args);
    if (error) throw error;
    return data;
  }

  async function runAction(action, onError = null) {
    if (busy) return;
    const session = epoch;
    setBusy(true);
    try {
      await action();
      if (session !== epoch || !account) return;
      // An older background read must finish before reading the mutation result.
      if (updatePromise) await updatePromise.catch(() => {});
      if (session === epoch) await update(true);
    } catch (error) {
      if (session === epoch) {
        banner(errorText(error), 'error');
        onError?.(error);
        if ($('offerDialog').open) {
          $('offerError').textContent = errorText(error); show('offerError', true);
        }
      }
    } finally {
      if (session === epoch) setBusy(false);
    }
  }

  function syncError(error) {
    if (!account) return;
    $('lastUpdate').classList.add('stale');
    $('lastUpdate').textContent = 'Не удалось обновить данные. ' +
      (lastSync ? 'Последнее обновление: ' + lastSync.toLocaleTimeString('ru-RU') : 'Проверьте соединение.');
    banner('Ошибка синхронизации: ' + errorText(error), 'error');
    if ($('offerDialog').open) {
      $('offerError').textContent = 'Не удалось обновить заказ. Проверь соединение.';
      show('offerError', true);
    }
  }

  function refresh() {
    return update(false).catch(syncError);
  }

  async function update(manual = false) {
    if (!sb || !account) return;
    if (updatePromise) return updatePromise;
    const session = epoch, client = sb, user = account, currentRole = role;
    const job = (async () => {
      await rpc('orbita_tick');
      const orders = await rpc('orbita_list_orders') || [];
      if (!Array.isArray(orders)) throw new Error('Сервер вернул неверный список заказов.');
      let profile = null, drivers = [];
      if (currentRole === 'driver') {
        const result = await client.from('orbita_drivers')
          .select('driver_name,car_model,plate,approved,on_line')
          .eq('user_id', user.id).maybeSingle();
        if (result.error) throw result.error;
        profile = result.data;
      }
      if (currentRole === 'admin') {
        drivers = await rpc('orbita_admin_list_drivers') || [];
        if (!Array.isArray(drivers)) throw new Error('Сервер вернул неверный список водителей.');
      }
      if (session !== epoch) return;
      currentOrders = orders;
      if (currentRole === 'driver') { driver = profile; renderDriver(); }
      if (currentRole === 'admin') { adminDrivers = drivers; renderAdmin(); }
      if (currentRole === 'passenger' || currentRole === 'admin') renderPassenger();
      lastSync = new Date();
      $('lastUpdate').classList.remove('stale');
      $('lastUpdate').textContent = 'Сервер обновлён: ' + lastSync.toLocaleTimeString('ru-RU');
      if (manual) banner('Данные обновлены с сервера.', 'success');
    })();
    updatePromise = job;
    try { await job; }
    finally { if (updatePromise === job) updatePromise = null; }
  }

  function ownOrders(userId) {
    return currentOrders.filter(order => same(order.driver_id, userId));
  }

  function activeTrip(userId) {
    return ownOrders(userId).find(order => tripStatuses.has(order.status));
  }

  function offerIsLive(order) {
    return order?.status === 'offered' && Number.isFinite(Date.parse(order.offered_until)) &&
      Date.parse(order.offered_until) > Date.now();
  }

  function keyForOffer(order) {
    return account.id + ':' + order.id + ':' + order.offered_until;
  }

  function renderOrder(order, who) {
    const card = text('article', '', 'order');
    card.dataset.orderId = String(order.id);
    const header = text('div', '', 'order-head');
    header.append(text('strong', 'Заказ №' + order.id),
      badge(labels[order.status] || order.status,
        ['accepted', 'completed'].includes(order.status) ? 'good' : 'wait'));
    card.append(header, text('p', '📍 ' + order.pickup), text('p', '🏁 ' + order.destination));
    if (order.driver_name) card.append(text('p', '🚕 ' + order.driver_name + ' · ' +
      (order.car_model || 'Автомобиль') + ' · ' + (order.plate || ''), 'muted'));
    const actions = text('div', '', 'actions');
    if (who === 'passenger' && ['new', 'offered', 'accepted', 'arrived'].includes(order.status)) {
      actions.append(mutationButton('Отменить', async () => {
        if (confirm('Отменить тестовый заказ №' + order.id + '?')) {
          await rpc('orbita_cancel_order', { p_order_id: order.id });
        }
      }, 'danger'));
    }
    if (who === 'driver' && same(order.driver_id, account.id)) {
      const steps = {
        accepted: ['Я на месте', 'arrived'], arrived: ['Начать поездку', 'on_trip'],
        on_trip: ['Завершить поездку', 'completed'],
      };
      if (steps[order.status]) {
        const [label, status] = steps[order.status];
        actions.append(mutationButton(label, () => rpc('orbita_driver_progress', {
          p_order_id: order.id, p_status: status,
        }), ''));
      }
      if (offerIsLive(order)) card.append(text('p', 'Предложение ожидает ответа.', 'mini'));
    }
    if (actions.children.length) card.append(actions);
    return card;
  }

  function renderPassenger() {
    const area = $('passengerOrders');
    area.replaceChildren();
    const mine = currentOrders.filter(order => same(order.passenger_id, account.id));
    $('orderForm').querySelector('button').disabled = busy || mine.some(order => activeStatuses.has(order.status));
    if (!mine.length) area.append(text('p', 'Поездок пока нет. Создай тестовый заказ.', 'empty'));
    mine.slice(0, 12).forEach(order => area.append(renderOrder(order, 'passenger')));
  }

  function setShiftButtons() {
    if (!account || role !== 'driver') return;
    const trip = activeTrip(account.id);
    $('online').disabled = busy || !driver?.approved || !!driver?.on_line || !!trip;
    $('offline').disabled = busy || !driver?.approved || !driver?.on_line || !!trip;
  }

  function renderDriver() {
    const mine = ownOrders(account.id), trip = activeTrip(account.id);
    const offer = mine.find(offerIsLive);
    const approved = driver?.approved === true, online = driver?.on_line === true;
    $('driverName').textContent = driver?.driver_name || 'Профиль водителя отсутствует';
    $('carName').textContent = driver ? driver.car_model + ' · ' + driver.plate :
      'Добавить водителя может только администратор';
    // A revoked driver still sees and finishes their accepted trip. No access
    // message or sound is emitted until it is terminal. The server enforces this.
    $('driverState').textContent = trip ? driverLabels[trip.status] : offer ?
      driverLabels.offered : !approved ? 'Доступ ограничен' : online ? 'На линии' : 'Не на линии';
    $('driverState').className = 'badge ' + (trip || approved && online ? 'good' : 'wait');
    show('driverAccessMessage', !approved && !trip);
    $('driverAccessMessage').textContent = driver ?
      'Доступ к новым заказам ограничен. Для возобновления работы свяжись с администратором.' :
      'Профиль водителя пока не создан. Обратись к администратору.';
    show('shiftControls', approved && !trip);
    setShiftButtons();

    const current = $('driverCurrentOrders');
    current.replaceChildren();
    const active = mine.filter(order => tripStatuses.has(order.status) || offerIsLive(order));
    if (active.length) active.forEach(order => current.append(renderOrder(order, 'driver')));
    else current.append(text('p', approved ? online ?
      'Ты на линии. Новое предложение откроется поверх страницы.' :
      'Выйди на линию, чтобы получать заказы.' : 'Новые заказы недоступны.', 'empty'));
    const history = $('driverOrders');
    history.replaceChildren();
    mine.filter(order => !activeStatuses.has(order.status)).slice(0, 12)
      .forEach(order => history.append(renderOrder(order, 'history')));
    if (!history.children.length) history.append(text('p', 'Завершённых поездок пока нет.', 'empty'));

    syncOffer(offer && approved ? offer : null);
    const tripKey = trip ? String(trip.id) : null;
    if (tripKey && tripKey !== lastDriverOrder) $('driverBox').scrollIntoView({ block: 'start' });
    lastDriverOrder = tripKey;
  }

  function renderAdmin() {
    const area = $('adminDrivers');
    area.replaceChildren();
    $('totalDrivers').textContent = adminDrivers.length;
    $('totalOrders').textContent = currentOrders.length;
    if (!adminDrivers.length) area.append(text('p', 'Водителей пока нет.', 'empty'));
    adminDrivers.forEach((d, index) => {
      const assigned = ownOrders(d.user_id);
      const trip = assigned.find(order => tripStatuses.has(order.status));
      const offer = assigned.find(offerIsLive), order = trip || offer;
      const card = text('article', '', 'order');
      card.dataset.driverId = String(d.user_id);
      const header = text('div', '', 'two');
      header.append(text('strong', (index + 1) + '. ' + d.name));
      const operation = order ? driverLabels[order.status] : !d.approved ?
        'Доступ ограничен' : d.on_line ? 'Свободен · на линии' : 'Не на линии';
      header.append(badge(operation, order || d.approved && d.on_line ? 'good' : 'wait'));
      card.append(header, text('p', d.car + ' · ' + d.plate, 'mini'), text('p', d.email, 'mini'));
      if (order) {
        const current = text('div', '', 'driver-current');
        current.append(text('strong', 'Текущий заказ №' + order.id),
          text('p', '📍 ' + order.pickup), text('p', '🏁 ' + order.destination));
        card.append(current);
      }
      if (!d.approved) card.append(text('p', trip ?
        'Новые заказы отключены. Водитель завершает текущую поездку.' :
        'Новые заказы отключены.', 'access-note'));
      card.append(mutationButton(d.approved ? 'Ограничить доступ' : 'Восстановить доступ',
        () => rpc('orbita_admin_approve_driver', {
          p_driver_id: d.user_id, p_approved: !d.approved,
        }), d.approved ? 'danger' : ''));
      area.append(card);
    });
    const orders = $('adminOrders');
    orders.replaceChildren();
    if (!currentOrders.length) orders.append(text('p', 'Заказов пока нет.', 'empty'));
    currentOrders.slice(0, 25).forEach(order => orders.append(renderOrder(order, 'admin')));
  }

  function configFromStorage() {
    try { return JSON.parse(localStorage.getItem('orbita-auth-v02-config') ||
      localStorage.getItem('orbita-live-v02-config') || 'null'); }
    catch (_) { return null; }
  }

  async function connect(url, key) {
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(url) ||
        !/^sb_publishable_[a-z0-9_-]{10,}$/i.test(key)) {
      throw new Error('Нужны Project URL и публичный sb_publishable_…');
    }
    if (!window.supabase?.createClient) throw new Error('Не загрузилась библиотека Supabase.');
    sb = window.supabase.createClient(url.replace(/\/$/, ''), key, {
      auth: { persistSession: true, autoRefreshToken: true,
        detectSessionInUrl: false, storageKey: 'orbita-auth-v02-session' },
    });
    localStorage.setItem('orbita-live-v02-config', JSON.stringify({ url, key }));
    const { data, error } = await sb.auth.getUser();
    if (error && !/missing auth session|auth session missing/i.test(error.message)) throw error;
    show('connectBox', false);
    if (data?.user) await entered(data.user);
    else { show('loginBox', true); banner('Подключение настроено. Войди в тестовый аккаунт.', 'success'); }
  }

  async function entered(user) {
    epoch += 1;
    account = user;
    const { data, error } = await sb.from('orbita_profiles').select('role')
      .eq('user_id', user.id).maybeSingle();
    if (error) throw error;
    if (!['driver', 'passenger', 'admin'].includes(data?.role)) {
      throw new Error('Не найдена роль пользователя. Обратитесь к администратору.');
    }
    role = data.role;
    $('accountEmail').textContent = user.email || 'Пользователь';
    $('accountRole').textContent = role;
    show('loginBox', false); show('app', true);
    show('passengerBox', role === 'passenger' || role === 'admin');
    show('driverBox', role === 'driver'); show('adminBox', role === 'admin');
    show('mapBox', role === 'passenger' || role === 'admin');
    $('roleLayout').classList.toggle('driver-only', role === 'driver');
    if (role !== 'driver') setupMap();
    clearInterval(interval);
    // Background polling is best effort; it is not a replacement for Web Push.
    interval = setInterval(() => {
      if (!document.hidden || role === 'driver') refresh();
    }, role === 'driver' ? 2000 : 4500);
    await update(true);
    if (role === 'driver') restoreNotificationPreference();
  }

  async function logout() {
    if (busy) return;
    setBusy(true);
    try {
      const { error } = await sb.auth.signOut();
      if (error) throw error;
      epoch += 1;
      clearInterval(interval);
      syncOffer(null);
      account = null; role = null; driver = null;
      currentOrders = []; adminDrivers = []; lastDriverOrder = null;
      soundedOffers.clear();
      show('app', false); show('loginBox', true);
      banner('Ты вышел из аккаунта.', 'success');
    } catch (error) { banner(errorText(error), 'error'); }
    finally { setBusy(false); }
  }

  function setupMap() {
    if (map) return;
    if (!window.L) { $('map').textContent = 'Карта недоступна. Заказ можно создать по адресу.'; return; }
    map = L.map('map', { zoomControl: true }).setView([54.995, 82.443], 14);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© OpenStreetMap contributors',
    }).addTo(map);
    map.on('click', event => {
      const mode = document.querySelector('input[name="pinType"]:checked')?.value || 'pickup';
      const coords = [+event.latlng.lat.toFixed(6), +event.latlng.lng.toFixed(6)];
      if (mode === 'pickup') {
        pickupCoords = coords;
        pickupMark?.remove();
        pickupMark = L.marker(coords).addTo(map).bindPopup('Точка подачи').openPopup();
        $('pickup').value = 'Точка на карте (подача)';
      } else {
        destinationCoords = coords;
        destinationMark?.remove();
        destinationMark = L.marker(coords).addTo(map).bindPopup('Пункт назначения').openPopup();
        $('destination').value = 'Точка на карте (назначение)';
      }
    });
    setTimeout(() => map.invalidateSize(), 100);
  }

  function soundControls() {
    const ready = soundEnabled && audio?.state === 'running';
    $('soundToggle').textContent = ready ? 'Выключить звук заказов' : 'Включить звук заказов';
    $('soundToggle').setAttribute('aria-pressed', String(!!ready));
    $('offerSound').textContent = ready ? 'Выключить звук' : 'Включить звук';
    $('soundStatus').textContent = ready ? 'Звук включён. Проверь громкость устройства.' :
      'Для звукового сигнала нажми «Включить звук заказов».';
  }

  function tone() {
    if (!soundEnabled || audio?.state !== 'running') return;
    const start = audio.currentTime;
    [0, 0.3].forEach((offset, index) => {
      const oscillator = audio.createOscillator(), gain = audio.createGain();
      oscillator.type = 'sine';
      oscillator.frequency.value = index ? 880 : 660;
      gain.gain.setValueAtTime(0, start + offset);
      gain.gain.linearRampToValueAtTime(0.18, start + offset + 0.025);
      gain.gain.linearRampToValueAtTime(0, start + offset + 0.23);
      oscillator.connect(gain); gain.connect(audio.destination);
      soundNodes.add(oscillator);
      oscillator.onended = () => {
        soundNodes.delete(oscillator); oscillator.disconnect(); gain.disconnect();
      };
      oscillator.start(start + offset); oscillator.stop(start + offset + 0.25);
    });
  }

  function stopRinging() {
    clearInterval(ringTimer); ringTimer = null;
    soundNodes.forEach(node => { try { node.stop(); } catch (_) {} });
    soundNodes.clear();
  }

  function startRinging() {
    stopRinging();
    if (!currentOffer || !offerIsLive(currentOffer) || !soundEnabled) return;
    tone();
    ringTimer = setInterval(() => {
      if (currentOffer && offerIsLive(currentOffer)) tone();
      else stopRinging();
    }, 1800);
  }

  async function enableSound(test = true) {
    try {
      const Audio = window.AudioContext || window.webkitAudioContext;
      if (!Audio) throw new Error('Этот браузер не поддерживает звуковой сигнал.');
      if (!audio || audio.state === 'closed') audio = new Audio();
      // Must be called directly from a user gesture on mobile browsers.
      await audio.resume();
      soundEnabled = audio.state === 'running';
      pref('sound', soundEnabled ? 'on' : 'off');
      soundControls();
      if (currentOffer) startRinging();
      else if (test) tone();
    } catch (error) {
      soundEnabled = false; soundControls();
      $('soundStatus').textContent = errorText(error);
    }
  }

  function toggleSound() {
    if (!soundEnabled || audio?.state !== 'running') { enableSound(); return; }
    soundEnabled = false; pref('sound', 'off'); stopRinging(); soundControls();
  }

  function closeNotifications() {
    notificationHandle?.close(); notificationHandle = null;
    const tag = notificationTag; notificationTag = null;
    if (tag && notificationRegistration?.getNotifications) {
      notificationRegistration.getNotifications({ tag }).then(items => {
        items.forEach(item => item.close());
      }).catch(() => {});
    }
  }

  async function registerNotifications() {
    if ('serviceWorker' in navigator && window.isSecureContext) {
      // This scope covers only the new page. There is no fetch/cache handler.
      notificationRegistration = await navigator.serviceWorker.register(
        './orbita-driver-sw-0.3.js', { scope: './orbita-live-0.3.html' });
      const worker = notificationRegistration.installing || notificationRegistration.waiting;
      if (worker && worker.state !== 'activated') {
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('Повтори включение уведомлений.')), 10000);
          worker.addEventListener('statechange', () => {
            if (worker.state === 'activated') { clearTimeout(timer); resolve(); }
            else if (worker.state === 'redundant') {
              clearTimeout(timer); reject(new Error('Не удалось включить уведомления.'));
            }
          });
        });
      }
    }
  }

  function notificationControls() {
    $('notificationToggle').textContent = notificationsEnabled ?
      'Выключить уведомления' : 'Включить уведомления';
    $('notificationToggle').setAttribute('aria-pressed', String(notificationsEnabled));
    $('notificationStatus').textContent = notificationsEnabled ?
      'Уведомления включены. Держи приложение открытым для получения заказов.' :
      'Чтобы получать новые заказы, держи приложение открытым.';
  }

  async function restoreNotificationPreference() {
    if (pref('notifications') !== 'on' || !('Notification' in window) ||
        Notification.permission !== 'granted') return;
    try {
      await registerNotifications(); notificationsEnabled = true; notificationControls();
      if (currentOffer) notifyOffer(currentOffer);
    } catch (_) { /* The offer dialog remains available without notifications. */ }
  }

  async function toggleNotifications() {
    if (notificationsEnabled) {
      notificationsEnabled = false; pref('notifications', 'off');
      closeNotifications(); notificationControls(); return;
    }
    if (!('Notification' in window) || !window.isSecureContext) {
      $('notificationStatus').textContent = 'В этом браузере системные уведомления недоступны. Окно заказа работает в приложении.';
      return;
    }
    try {
      const permission = Notification.permission === 'default' ?
        await Notification.requestPermission() : Notification.permission;
      if (permission !== 'granted') {
        $('notificationStatus').textContent = permission === 'denied' ?
          'Уведомления запрещены в настройках браузера. Окно заказа работает в приложении.' :
          'Разрешение на уведомления не получено. Окно заказа работает в приложении.';
        return;
      }
      await registerNotifications();
      notificationsEnabled = true; pref('notifications', 'on'); notificationControls();
      if (currentOffer) notifyOffer(currentOffer);
    } catch (error) { $('notificationStatus').textContent = errorText(error); }
  }

  async function notifyOffer(order) {
    if (!notificationsEnabled || Notification.permission !== 'granted') return;
    const key = keyForOffer(order), tag = 'orbita-offer-' + key;
    if (notificationTag === tag) return;
    closeNotifications(); notificationTag = tag;
    const options = { body: order.pickup + ' → ' + order.destination, tag,
      requireInteraction: true, data: { url: new URL('./orbita-live-0.3.html', location.href).href } };
    try {
      if (notificationRegistration?.showNotification) {
        await notificationRegistration.showNotification('ОРБИТА · Заказ №' + order.id, options);
        if (displayedOfferKey !== key) {
          const items = await notificationRegistration.getNotifications({ tag });
          items.forEach(item => item.close());
        }
      } else {
        notificationHandle = new Notification('ОРБИТА · Заказ №' + order.id, options);
        notificationHandle.onclick = () => { window.focus(); refresh(); };
      }
    } catch (_) {
      $('notificationStatus').textContent = 'Системное уведомление недоступно. Следи за окном заказа в приложении.';
    }
  }

  function refreshCountdown() {
    if (!currentOffer) return;
    const seconds = Math.max(0, Math.ceil((Date.parse(currentOffer.offered_until) - Date.now()) / 1000));
    $('offerCountdown').textContent = seconds + ' сек';
    $('offerAccept').disabled = busy || seconds <= 0 || !navigator.onLine;
    $('offerDecline').disabled = busy || seconds <= 0 || !navigator.onLine;
    show('offerConnection', !navigator.onLine);
    if (!seconds) {
      syncOffer(null);
      if (account) refresh();
    }
  }

  function syncOffer(order) {
    if (!order || !account || role !== 'driver' || !offerIsLive(order)) {
      currentOffer = null; displayedOfferKey = null;
      clearInterval(offerTimer); offerTimer = null;
      stopRinging(); closeNotifications();
      if ($('offerDialog').open) $('offerDialog').close();
      document.title = title;
      return;
    }
    currentOffer = order;
    const key = keyForOffer(order), fresh = displayedOfferKey !== key;
    if (fresh) {
      stopRinging(); closeNotifications(); displayedOfferKey = key;
      show('offerError', false);
      $('offerHeading').textContent = 'Заказ №' + order.id;
      $('offerPickup').textContent = order.pickup;
      $('offerDestination').textContent = order.destination;
      document.title = 'Новый заказ №' + order.id + ' · ОРБИТА';
      if (!$('offerDialog').open) $('offerDialog').showModal();
      clearInterval(offerTimer);
      offerTimer = setInterval(refreshCountdown, 250);
      if (!soundedOffers.has(key)) {
        soundedOffers.add(key); startRinging(); notifyOffer(order);
      }
    }
    refreshCountdown(); soundControls();
  }

  async function respondToOffer(accept) {
    const order = currentOffer;
    if (!order || !offerIsLive(order) || busy || !navigator.onLine) return;
    show('offerError', false);
    stopRinging(); closeNotifications();
    await runAction(() => rpc('orbita_driver_respond', {
      p_order_id: order.id, p_accept: accept,
    }));
    if (currentOffer && offerIsLive(currentOffer)) startRinging();
  }

  $('offerDialog').addEventListener('cancel', event => event.preventDefault());
  $('offerAccept').addEventListener('click', () => respondToOffer(true));
  $('offerDecline').addEventListener('click', () => respondToOffer(false));
  $('offerSound').addEventListener('click', toggleSound);
  $('soundToggle').addEventListener('click', toggleSound);
  $('notificationToggle').addEventListener('click', toggleNotifications);
  $('connectForm').addEventListener('submit', async event => {
    event.preventDefault();
    const button = $('connectForm').querySelector('button'); button.disabled = true;
    try { await connect($('sbUrl').value.trim(), $('sbKey').value.trim()); }
    catch (error) { show('connectBox', true); banner(errorText(error), 'error'); }
    finally { button.disabled = false; }
  });
  $('loginForm').addEventListener('submit', async event => {
    event.preventDefault();
    if (busy) return;
    const password = $('password').value;
    $('password').value = '';
    setBusy(true);
    try {
      const { data, error } = await sb.auth.signInWithPassword({
        email: $('email').value.trim(), password,
      });
      if (error) throw error;
      await entered(data.user);
    } catch (error) { banner(errorText(error), 'error'); }
    finally { setBusy(false); }
  });
  $('logout').addEventListener('click', logout);
  $('refresh').addEventListener('click', () => update(true).catch(syncError));
  $('online').addEventListener('click', () => {
    // Going online is a user gesture that unlocks mobile audio.
    enableSound(false);
    runAction(() => rpc('orbita_driver_online', { p_online: true }));
  });
  $('offline').addEventListener('click', () => runAction(() => rpc('orbita_driver_online', { p_online: false })));
  $('orderForm').addEventListener('submit', event => {
    event.preventDefault();
    runAction(() => rpc('orbita_create_order', {
      p_pickup: $('pickup').value.trim(), p_destination: $('destination').value.trim(),
      p_pickup_lat: pickupCoords?.[0] ?? null, p_pickup_lng: pickupCoords?.[1] ?? null,
      p_destination_lat: destinationCoords?.[0] ?? null, p_destination_lng: destinationCoords?.[1] ?? null,
    }));
  });
  $('addDriverForm').addEventListener('submit', event => {
    event.preventDefault();
    runAction(async () => {
      await rpc('orbita_admin_add_driver', {
        p_email: $('dEmail').value.trim(), p_name: $('dName').value.trim(),
        p_car: $('dCar').value.trim(), p_plate: $('dPlate').value.trim(),
      });
      $('addDriverForm').reset();
    });
  });
  $('pickup').addEventListener('input', () => { pickupCoords = null; pickupMark?.remove(); pickupMark = null; });
  $('destination').addEventListener('input', () => { destinationCoords = null; destinationMark?.remove(); destinationMark = null; });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && account) refresh(); });
  window.addEventListener('online', () => { refreshCountdown(); if (account) refresh(); });
  window.addEventListener('offline', () => {
    refreshCountdown();
    if (account) syncError(new Error('Нет подключения к интернету.'));
  });
  navigator.serviceWorker?.addEventListener('message', event => {
    if (event.data?.type === 'orbita-open-offer' && account) refresh();
  });
  document.addEventListener('pointerdown', () => {
    if (role === 'driver' && pref('sound') === 'on' && audio?.state !== 'running') enableSound(false);
  });
  soundControls(); notificationControls();
  const config = configFromStorage();
  if (config?.url && config?.key) {
    connect(config.url, config.key).catch(error => {
      show('connectBox', true); $('sbUrl').value = config.url; $('sbKey').value = config.key;
      banner('Не удалось подключиться: ' + errorText(error), 'error');
    });
  } else { show('connectBox', true); banner('Введите публичные настройки Supabase (один раз).'); }
})();
