import 'dart:async';

import 'package:flutter/material.dart';

import '../api/talk_api.dart';
import '../models/contact_item.dart';
import '../widgets/avatars.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.api});
  final NextcloudTalkApi api;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with AutomaticKeepAliveClientMixin {
  List<ContactItem>? _contacts; // последний успешный срез
  bool _loading = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _fetch(initial: true);
    _ticker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _fetch(silent: true),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _fetch({bool initial = false, bool silent = false}) async {
    if (_loading) return;
    if (!mounted) return;
    setState(() => _loading = !silent && initial && (_contacts == null));
    try {
      final data = await _loadContacts();
      if (!mounted) return;
      setState(() => _contacts = data);
    } catch (_) {
      // оставляем предыдущий список (тихий фейл)
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<ContactItem>> _loadContacts() async {
    final rooms = await widget.api.listRooms(includeStatus: true);
    final me = widget.api.username;
    final oneToOne = rooms.where((r) => r.type == 1).toList();

    final out = <ContactItem>[];
    for (final r in oneToOne) {
      try {
        final parts = await widget.api.listParticipants(
          r.token,
          includeStatus: true,
        );
        final other = parts.firstWhere(
          (p) =>
              (p.actorType.toLowerCase() == 'user' ||
                  p.actorType.toLowerCase() == 'users' ||
                  p.actorType.toLowerCase() == 'federated_users') &&
              (p.actorId ?? '') != me,
          orElse: () => NcParticipant(
            actorType: 'users',
            actorId: r.displayName,
            displayName: r.displayName,
          ),
        );
        out.add(
          ContactItem(
            userId: other.actorId ?? r.displayName,
            displayName: (other.displayName?.isNotEmpty ?? false)
                ? other.displayName!
                : (other.actorId ?? r.displayName),
            roomToken: r.token,
          ),
        );
      } catch (_) {
        out.add(
          ContactItem(
            userId: r.displayName,
            displayName: r.displayName,
            roomToken: r.token,
          ),
        );
      }
    }

    out.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return out;
  }

  Future<void> _refresh() => _fetch();

  Future<void> _startChat(ContactItem c) async {
    try {
      final room = NcRoom(
        token: c.roomToken,
        displayName: c.displayName,
        type: 1,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(api: widget.api, room: room),
        ),
      );
      _fetch(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Не удалось начать чат: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final contacts = _contacts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Контакты'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _loading && contacts == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
          ),
        ],
      ),
      body: contacts == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: contacts.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final c = contacts[i];
                  return ListTile(
                    key: ValueKey(c.roomToken),
                    leading: NcAvatar.user(
                      api: widget.api,
                      userId: c.userId,
                      displayName: c.displayName,
                      radius: 20,
                    ),
                    title: Text(c.displayName),
                    trailing: IconButton(
                      icon: const Icon(Icons.textsms_outlined),
                      tooltip: 'Начать переписку',
                      onPressed: () => _startChat(c),
                    ),
                    onTap: () => _startChat(c),
                  );
                },
              ),
            ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
