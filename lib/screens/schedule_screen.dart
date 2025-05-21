import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:timefulness/models/prefs.dart';
import 'package:timefulness/screens/settings_screen.dart';
import 'package:timefulness/services/hive_schedule_repository.dart';
import 'package:timefulness/widgets/duration_dial.dart';
import 'package:timefulness/widgets/solid_visual_timer.dart';
import '../models/schedule_item.dart';
import '../widgets/schedule_tile.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<ScheduleItem> schedule = [];
  TimeOfDay? selectedStartTime;
  int durationMinutes = 50; // Default duration of 30 minutes
  final _activityController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isDefaultScheduleLoaded = false;
  late final HiveScheduleRepository scheduleRepo;
  static const String defaultScheduleId = 'default';
  int _activeDuration = 0;
  int _remainingSeconds = 0;
  Timer? _countdownTimer;
  bool _timerVisible = false;

  @override
  void initState() {
    super.initState();
    final box = Hive.box('schedules');
    scheduleRepo = HiveScheduleRepository(box);
    _loadSchedule();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay time) {
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    return DateFormat.jm().format(dt); // e.g., 6:30 AM
  }

  TimeOfDay _addDurationToTime(TimeOfDay startTime, int durationMinutes) {
    int totalMinutes = startTime.hour * 60 + startTime.minute + durationMinutes;
    int newHour = (totalMinutes ~/ 60) % 24;
    int newMinute = totalMinutes % 60;
    return TimeOfDay(hour: newHour, minute: newMinute);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: selectedStartTime ?? TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() {
        selectedStartTime = picked;
      });
    }
  }

  Future<void> _saveSchedule() async {
    final activeId =
        await scheduleRepo.getActiveScheduleId() ?? defaultScheduleId;
    await scheduleRepo.saveSchedule(activeId, schedule);
  }

  Future<void> _loadSchedule() async {
    final activeId = await scheduleRepo.getActiveScheduleId();
    if (activeId == null) {
      debugPrint("⚠️ No active schedule ID found. Defaulting to 'default'");
      await scheduleRepo.setActiveScheduleId(defaultScheduleId);
      return _loadSchedule(); // try again
    }

    final items = await scheduleRepo.loadSchedule(activeId);

    setState(() {
      schedule = items;
    });

    _sortScheduleByTime();
    await _checkForMidnightReset();
  }

  Future<void> _loadDefaultSchedule() async {
    try {
      // Load CSV file from assets
      final String csvString = await rootBundle.loadString(
        'assets/daily schedule - Sheet1.csv',
      );
      debugPrint("📄 CSV raw content:\n$csvString");

      // Parse CSV
      List<List<dynamic>> csvTable = const CsvToListConverter().convert(
        csvString,
      );

      // Skip header row
      if (csvTable.length > 1) {
        // Start from index 1 to skip header
        // 🟢 Replace with mapped parsing from CSV header
        final headers = csvTable.first.cast<String>(); // 🟢
        final rows = csvTable.skip(1); // 🟢

        final defaultSchedule =
            rows.map((row) {
              // 🟢
              final map = Map<String, dynamic>.fromIterables(
                headers,
                row,
              ); // 🟢
              return ScheduleItem.fromCsv(map); // 🟢
            }).toList();
        setState(() {
          schedule = defaultSchedule;
          _isDefaultScheduleLoaded = true;
          _sortScheduleByTime();
        });

        // Save the default schedule
        await _saveSchedule();
      }
    } catch (e) {
      debugPrint('Error loading default schedule: $e');
    }
  }

  void _addScheduleItem() {
    if (selectedStartTime == null || _activityController.text.isEmpty) return;

    // Calculate end time based on start time and duration
    final endTime = _addDurationToTime(selectedStartTime!, durationMinutes);

    setState(() {
      schedule.add(
        ScheduleItem(
          id: UniqueKey().toString(),
          startTime: _formatTime(selectedStartTime!),
          endTime: _formatTime(endTime),
          activity: _activityController.text,
          checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
      _sortScheduleByTime();
    });
    _saveSchedule();
    _activityController.clear();
    selectedStartTime = null;
    Navigator.of(context).pop();
  }

  void _updateScheduleItem(int index) {
    if (selectedStartTime == null || _activityController.text.isEmpty) return;

    // Calculate end time based on start time and duration
    final endTime = _addDurationToTime(selectedStartTime!, durationMinutes);

    setState(() {
      schedule[index] = ScheduleItem(
        id: schedule[index].id,
        startTime: _formatTime(selectedStartTime!),
        endTime: _formatTime(endTime),
        activity: _activityController.text,
        done: schedule[index].done,
        checkedAt: schedule[index].checkedAt,
      );
      _sortScheduleByTime();
    });
    _saveSchedule();
    _activityController.clear();
    selectedStartTime = null;
    Navigator.of(context).pop();
  }

  Future<void> _playBellSound({bool timer = false}) async {
    String soundFile =
        timer ? 'bell-meditation-75335.mp3' : 'bell-meditation-trim.mp3';

    try {
      final player = AudioPlayer(); // Create a fresh instance each time
      await player.play(AssetSource(soundFile));
      // Dispose after sound finishes (non-blocking)
      player.onPlayerComplete.listen((event) {
        player.dispose();
      });
    } catch (e) {
      debugPrint('Error playing bell sound: $e');
    }
  }

  void _updateItem(int index, bool? value) {
    final bool newValue = value ?? false;

    setState(() {
      schedule[index].done = newValue;
      schedule[index].checkedAt =
          newValue ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(0);
    });

    // Play bell sound when item is checked (marked as done)
    if (newValue) {
      _playBellSound();
    }

    _saveSchedule();
  }

  void _deleteItem(int index) {
    setState(() {
      schedule.removeAt(index);
    });
    _saveSchedule();
  }

  void _sortScheduleByTime() {
    final format = DateFormat('h:mm a', 'en_US');
    schedule.sort((a, b) {
      try {
        final aTime = format.parseStrict(_cleanTime(a.startTime));
        final bTime = format.parseStrict(_cleanTime(b.startTime));
        return aTime.compareTo(bTime);
      } catch (e) {
        debugPrint('❌ Error parsing time during sort: $e');
        return 0;
      }
    });
  }

  void _startVisualTimer(int index) {
    if (_countdownTimer != null && _countdownTimer!.isActive) return;
    final item = schedule[index];
    final format = DateFormat('h:mm a', 'en_US');
    try {
      final start = format.parse(_cleanTime(item.startTime));
      final end = format.parse(_cleanTime(item.endTime));
      final duration = end.difference(start).inSeconds;
      WakelockPlus.enable();

      setState(() {
        _activeDuration = duration;
        _remainingSeconds = duration;
        _timerVisible = true;
      });

      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (
        timer,
      ) async {
        if (_remainingSeconds > 0) {
          setState(() => _remainingSeconds--);
        } else {
          timer.cancel();
          await _playBellSound(timer: true);
          WakelockPlus.disable();
          setState(() => _timerVisible = false);
        }
      });
    } catch (e) {
      debugPrint('❌ Could not start timer: $e');
    }
  }

  void _stopVisualTimer() {
    _countdownTimer?.cancel();
    WakelockPlus.disable();
    setState(() => _timerVisible = false);
  }

  Future<void> _checkForMidnightReset() async {
    final prefs = await SharedPreferences.getInstance();
    final lastResetDate = prefs.getString('lastResetDate');
    final today = DateTime.now().toIso8601String().substring(
      0,
      10,
    ); // 'YYYY-MM-DD'

    if (lastResetDate != today) {
      debugPrint("🌅 New day detected, resetting schedule");
      setState(() {
        for (var item in schedule) {
          item.done = false;
        }
      });
      await prefs.setString('lastResetDate', today);
      await _saveSchedule();
    }
  }

  String _cleanTime(String time) {
    return time
        .replaceAll(RegExp(r'[\u202F\u00A0]'), ' ') // Convert NBSP to space
        .replaceFirstMapped(
          RegExp(r'^(\d):'),
          (m) => '0${m[1]}:',
        ) // Add leading zero
        .trim();
  }

  void _editItem(int index) {
    final item = schedule[index];
    debugPrint('🕒 Editing item: "${item.activity}"');
    debugPrint('🔹 Raw start time: "${item.startTime}"');
    debugPrint('🔹 Raw end time: "${item.endTime}"');

    try {
      String timeString = item.startTime.trim(); // Ensure no extra spaces
      // Normalize to include leading zero if needed (e.g., "7:30 AM" -> "07:30 AM")
      timeString = timeString.replaceFirstMapped(
        RegExp(r'^(\d):'), // Match single-digit hour
        (match) => '0${match.group(1)}:', // Add leading zero
      );

      // Use en_US locale to ensure 12-hour format with AM/PM
      final format = DateFormat('h:mm a', 'en_US');
      final parsedStartTime = format.parseStrict(_cleanTime(item.startTime));
      /*
      DateTime parsedTime = DateFormat(
        'h:mm a',
        'en_US',
      ).parseStrict(timeString);
      selectedStartTime = TimeOfDay.fromDateTime(parsedTime);
*/

      _activityController.text = item.activity;
      final parsedEndTime = format.parseStrict(_cleanTime(item.endTime));

      final endTime = parsedEndTime;
      final durationInMinutes = endTime.difference(parsedStartTime).inMinutes;
      durationMinutes = durationInMinutes > 0 ? durationInMinutes : 50;

      selectedStartTime = TimeOfDay.fromDateTime(
        DateFormat('h:mm a', 'en_US').parseStrict(_cleanTime(item.startTime)),
      );

      _openAddDialog(isEditing: true, editIndex: index);
    } catch (e) {
      debugPrint('❌ FormatException in _editItem(): $e');
    }
  }

  void _openAddDialog({bool isEditing = false, int? editIndex}) {
    if (!isEditing) {
      // Reset duration to default when opening dialog for new item
      durationMinutes = 50;
      _activityController.clear();
      selectedStartTime = null;
    }

    showDialog(
      context: context,
      builder:
          (_) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text(
                  isEditing ? 'Edit Schedule Item' : 'Add Schedule Item',
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Start time picker
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            selectedStartTime != null
                                ? 'Start: ${_formatTime(selectedStartTime!)}'
                                : 'Start: (not selected)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          ElevatedButton(
                            onPressed: () async {
                              await _pickStartTime();
                              setDialogState(() {});
                            },
                            child: const Text('Change'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // Duration selector with dial
                      Text('Duration: $durationMinutes minutes'),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 200,
                        child: DurationDial(
                          initialDuration: durationMinutes,
                          onChanged: (newDuration) {
                            setDialogState(() {
                              durationMinutes = newDuration;
                            });
                          },
                        ),
                      ),

                      // Show calculated end time if start time is selected
                      if (selectedStartTime != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'End: ${_formatTime(_addDurationToTime(selectedStartTime!, durationMinutes))}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],

                      const SizedBox(height: 20),
                      TextField(
                        controller: _activityController,
                        decoration: const InputDecoration(
                          labelText: 'Activity',
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      if (isEditing && editIndex != null) {
                        _updateScheduleItem(editIndex);
                      } else {
                        _addScheduleItem();
                      }
                    },
                    child: Text(isEditing ? 'Update' : 'Add'),
                  ),
                ],
              );
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                'Menu',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            ListTile(
              leading: Icon(Icons.settings),
              title: Text('Settings'),
              onTap: () {
                Navigator.pop(context); // close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ).then(
                  (_) => setState(() {
                    _loadSchedule();
                  }),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.info),
              title: Text('About'),
              onTap: () {
                Navigator.pop(context);
                _showAboutDialog(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.help_outline),
              title: Text('Help'),
              onTap: () {
                Navigator.pop(context);
                _showHelpDialog(context);
              },
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: const Text('Daily Timefulness'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  )
                  .then(
                    (_) => setState(() {
                      _loadSchedule();
                    }),
                  );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_timerVisible)
            ElevatedButton(
              onPressed: _stopVisualTimer,
              child: Text("Stop Timer"),
            ),
          if (_timerVisible)
            SolidVisualTimer(
              remaining: _remainingSeconds,
              total: _activeDuration,
            ),
          Expanded(
            child: ListView.builder(
              itemCount: schedule.length,
              itemBuilder: (context, index) {
                final item = schedule[index];
                return ScheduleTile(
                  item: item,
                  onChanged: (value) => _updateItem(index, value),
                  onDelete: () => _deleteItem(index),
                  onEdit: () => _editItem(index),
                  onTap: () => _startVisualTimer(index),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Timefulness',
      applicationVersion: '1.0.0',
      applicationLegalese: '© 2025 Bhante Subhuti',
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Help'),
            content: const Text(
              '• Tap an item to start the timer.\n• Long-press to edit.\n• Use the menu for settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }
}
