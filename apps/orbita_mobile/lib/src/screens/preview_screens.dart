import 'package:flutter/material.dart';

import '../domain/contracts.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  void _open(BuildContext context, PreviewRole role) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => PreviewShell(role: role)));
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 32),
          Icon(
            Icons.blur_circular_rounded,
            size: 76,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 20),
          Text(
            'ОРБИТА',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge
                ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 4),
          ),
          const SizedBox(height: 8),
          const Text('Рядом, когда нужно ехать', textAlign: TextAlign.center),
          const SizedBox(height: 36),
          const SectionTitle('Знакомство с приложением'),
          const SizedBox(height: 8),
          const Text(
            'Тестовая основа Android. Выберите интерфейс для просмотра. Это не вход в аккаунт.',
          ),
          const SizedBox(height: 20),
          RoleCard(
            icon: Icons.person_outline,
            title: 'Пассажир',
            subtitle: 'Адреса, поездки и профиль',
            onTap: () => _open(context, PreviewRole.passenger),
          ),
          const SizedBox(height: 12),
          RoleCard(
            icon: Icons.local_taxi_outlined,
            title: 'Водитель',
            subtitle: 'Рабочий экран и данные автомобиля',
            onTap: () => _open(context, PreviewRole.driver),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/device-check'),
            icon: const Icon(Icons.phonelink_setup_outlined),
            label: const Text('Проверка телефона'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Вход, заказы и серверные уведомления ещё не подключены.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class RoleCard extends StatelessWidget {
  const RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      leading: Icon(
        icon,
        color: Theme.of(context).colorScheme.primary,
        size: 30,
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class PreviewShell extends StatefulWidget {
  const PreviewShell({required this.role, super.key});
  final PreviewRole role;
  @override
  State<PreviewShell> createState() => _PreviewShellState();
}

class _PreviewShellState extends State<PreviewShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final driver = widget.role == PreviewRole.driver;
    return Scaffold(
      appBar: AppBar(
        title: Text(driver ? 'Орбита · водитель' : 'Орбита · пассажир'),
        actions: [
          IconButton(
            tooltip: 'Проверка телефона',
            onPressed: () => Navigator.pushNamed(context, '/device-check'),
            icon: const Icon(Icons.phonelink_setup_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Notice(
              'Просмотр интерфейса · заказы недоступны',
              icon: Icons.science_outlined,
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                driver ? const DriverScreen() : const PassengerScreen(),
                const HistoryScreen(),
                ProfileScreen(driver: driver),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: [
          NavigationDestination(
            icon: Icon(
              driver ? Icons.local_taxi_outlined : Icons.place_outlined,
            ),
            label: driver ? 'Работа' : 'Заказ',
          ),
          const NavigationDestination(
            icon: Icon(Icons.history),
            label: 'Поездки',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}

class PassengerScreen extends StatelessWidget {
  const PassengerScreen({super.key});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const SectionTitle('Куда поедем?'),
      const SizedBox(height: 8),
      const Text('Чик, Прокудское и рядом'),
      const SizedBox(height: 16),
      const MapPlaceholder(),
      const SizedBox(height: 20),
      const TextField(
        key: Key('pickup'),
        decoration: InputDecoration(
          labelText: 'Откуда',
          prefixIcon: Icon(Icons.trip_origin),
        ),
      ),
      const SizedBox(height: 12),
      const TextField(
        key: Key('destination'),
        decoration: InputDecoration(
          labelText: 'Куда',
          prefixIcon: Icon(Icons.location_on_outlined),
        ),
      ),
      const SizedBox(height: 20),
      const FilledButton(onPressed: null, child: Text('Заказать такси')),
      const SizedBox(height: 12),
      const Text(
        'Можно посмотреть поля и навигацию. Заказ не отправляется, адреса не сохраняются.',
      ),
    ],
  );
}

class DriverScreen extends StatelessWidget {
  const DriverScreen({super.key});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle('Рабочий день'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: false,
                onChanged: null,
                title: Text('Не на линии'),
              ),
              Text(
                'Выход на линию станет доступен после входа и подключения сервера.',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      const MapPlaceholder(driver: true),
      const SizedBox(height: 16),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle('Текущий заказ'),
              SizedBox(height: 8),
              Text(
                'Назначенный заказ появится здесь. Предложения и очередь пока не подключены.',
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class MapPlaceholder extends StatelessWidget {
  const MapPlaceholder({this.driver = false, super.key});
  final bool driver;
  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minHeight: driver ? 240 : 170),
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: const Color(0xff17242b),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xff344752)),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.map_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        const Text(
          'Здесь будет карта',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Карта и положение автомобиля ещё не подключены.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: const [
      SizedBox(height: 40),
      Icon(Icons.history, size: 56),
      SizedBox(height: 20),
      Center(child: SectionTitle('Ваши поездки')),
      SizedBox(height: 12),
      Text(
        'История появится после подключения аккаунта. Тестовых заказов здесь нет.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({required this.driver, super.key});
  final bool driver;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      SectionTitle(driver ? 'Профиль водителя' : 'Профиль пассажира'),
      const SizedBox(height: 16),
      const Notice('Аккаунт не подключён', icon: Icons.lock_outline),
      const SizedBox(height: 16),
      Text(
        driver
            ? 'Имя и данные автомобиля будут получены после входа. Водительский аккаунт создаёт администратор.'
            : 'Вход и подтверждение телефона появятся на следующем этапе.',
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: () => Navigator.pushNamed(context, '/device-check'),
        icon: const Icon(Icons.phonelink_setup_outlined),
        label: const Text('Проверка телефона'),
      ),
      const SizedBox(height: 16),
      const Text('Орбита · тестовая основа 0.5.0'),
      const SizedBox(height: 8),
      const Text(
        'Выбор экрана для просмотра не предоставляет права пассажира или водителя на сервере.',
      ),
    ],
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w700),
  );
}

class Notice extends StatelessWidget {
  const Notice(this.text, {required this.icon, super.key});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xff29382a),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
