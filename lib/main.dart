import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'constants.dart';
import 'api/talk_api.dart';
import 'screens/login_screen.dart';
import 'screens/home_tabs.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TalkApp());
}

class TalkApp extends StatelessWidget {
  const TalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nextcloud Talk (media)',
      debugShowCheckedModeBanner: false,
      theme: kAppTheme,
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final storage = const FlutterSecureStorage();
  String? _user;
  String? _appPass;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await storage.read(key: 'nc_user');
    final p = await storage.read(key: 'nc_pass');
    if (!mounted) return;
    setState(() {
      _user = u;
      _appPass = p;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_user != null && _appPass != null) {
      return HomeTabs(api: NextcloudTalkApi(_user!, _appPass!));
    }
    return LoginScreen(
      onLogin: (u, p) async {
        await storage.write(key: 'nc_user', value: u);
        await storage.write(key: 'nc_pass', value: p);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeTabs(api: NextcloudTalkApi(u, p)),
          ),
        );
      },
    );
  }
}
