import 'package:flutter/material.dart';
import '../api/talk_api.dart';
import 'rooms_screen.dart';
import 'contacts_screen.dart';

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key, required this.api});
  final NextcloudTalkApi api;

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      RoomsScreen(api: widget.api),
      ContactsScreen(api: widget.api),
    ];

    return Scaffold(
      body: IndexedStack(index: _idx, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Чаты',
          ),
          NavigationDestination(
            icon: Icon(Icons.contacts_outlined),
            label: 'Контакты',
          ),
        ],
        onDestinationSelected: (i) => setState(() => _idx = i),
      ),
    );
  }
}
