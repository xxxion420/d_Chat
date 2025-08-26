import 'dart:async';

import 'package:flutter/material.dart';

import '../api/talk_api.dart';
import '../widgets/avatars.dart';
import 'chat_screen.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key, required this.api});
  final NextcloudTalkApi api;

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen>
    with AutomaticKeepAliveClientMixin {
  List<NcRoom>? _roomsData; // stale-while-refreshing
  bool _loading = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _fetchRooms(initial: true);
    _ticker = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetchRooms(silent: true),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _fetchRooms({bool initial = false, bool silent = false}) async {
    if (_loading) return;
    if (!mounted) return;
    setState(() => _loading = !silent && initial && (_roomsData == null));
    try {
      final data = await widget.api.listRooms(includeStatus: true);
      data.sort((a, b) => (b.lastActivity ?? 0).compareTo(a.lastActivity ?? 0));
      if (!mounted) return;
      setState(() => _roomsData = data);
    } catch (_) {
      // держим старый список
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() => _fetchRooms();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final rooms = _roomsData;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _loading && rooms == null
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
      body: rooms == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rooms.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = rooms[i];
                  final title = r.displayName.isEmpty ? r.token : r.displayName;
                  return ListTile(
                    key: ValueKey(r.token),
                    leading: RoomAvatar(api: widget.api, room: r, radius: 20),
                    title: Text(title),
                    subtitle: Text(
                      r.lastMessage ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(api: widget.api, room: r),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
