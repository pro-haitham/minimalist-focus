import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  runApp(const FocusTimerApp());
}

enum TimerPhase { focus, shortBreak, longBreak }
enum AppThemeMode { dark, oled, midnight }

class TimerPreset {
  final String name;
  final int focusMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;

  const TimerPreset({
    required this.name,
    required this.focusMinutes,
    required this.shortBreakMinutes,
    required this.longBreakMinutes,
  });
}

final List<TimerPreset> kBasePresets = [
  const TimerPreset(name: 'Classic', focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15),
  const TimerPreset(name: 'Deep Work', focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 20),
  const TimerPreset(name: 'Quick Sprint', focusMinutes: 15, shortBreakMinutes: 3, longBreakMinutes: 10),
];

class StudyTask {
  final String id;
  String title;
  bool isCompleted;
  int pomodorosCompleted;
  int estimatedPomodoros;
  String category; // e.g., 'University', 'Coding', 'Security', 'General'
  String notes;    // Session log / quick notes

  StudyTask({
    required this.id,
    required this.title,
    this.isCompleted = false,
    this.pomodorosCompleted = 0,
    this.estimatedPomodoros = 1,
    this.category = 'General',
    this.notes = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'isCompleted': isCompleted,
      'pomodorosCompleted': pomodorosCompleted,
      'estimatedPomodoros': estimatedPomodoros,
      'category': category,
      'notes': notes,
    };
  }

  factory StudyTask.fromMap(Map<String, dynamic> map) {
    return StudyTask(
      id: map['id'] as String,
      title: map['title'] as String,
      isCompleted: map['isCompleted'] as bool? ?? false,
      pomodorosCompleted: map['pomodorosCompleted'] as int? ?? 0,
      estimatedPomodoros: map['estimatedPomodoros'] as int? ?? 1,
      category: map['category'] as String? ?? 'General',
      notes: map['notes'] as String? ?? '',
    );
  }
}

class FocusTimerApp extends StatefulWidget {
  const FocusTimerApp({super.key});

  @override
  State<FocusTimerApp> createState() => _FocusTimerAppSharedState();

  static void setThemeMode(BuildContext context, AppThemeMode mode) {
    final state = context.findAncestorStateOfType<_FocusTimerAppSharedState>();
    state?.changeTheme(mode);
  }
}

class _FocusTimerAppSharedState extends State<FocusTimerApp> {
  AppThemeMode _currentTheme = AppThemeMode.dark;

  void changeTheme(AppThemeMode mode) {
    setState(() {
      _currentTheme = mode;
    });
  }

  Color get _bgScaffold {
    switch (_currentTheme) {
      case AppThemeMode.oled:
        return const Color(0xFF000000);
      case AppThemeMode.midnight:
        return const Color(0xFF0A0F1D);
      case AppThemeMode.dark:
        return const Color(0xFF0F1115);
    }
  }

  Color get _surfaceColor {
    switch (_currentTheme) {
      case AppThemeMode.oled:
        return const Color(0xFF121212);
      case AppThemeMode.midnight:
        return const Color(0xFF141D30);
      case AppThemeMode.dark:
        return const Color(0xFF181B20);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Minimalist Focus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bgScaffold,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF64FFDA),
          surface: _surfaceColor,
        ),
      ),
      home: PomodoroHomeScreen(currentTheme: _currentTheme),
    );
  }
}

class PomodoroHomeScreen extends StatefulWidget {
  final AppThemeMode currentTheme;
  const PomodoroHomeScreen({super.key, required this.currentTheme});

  @override
  State<PomodoroHomeScreen> createState() => _PomodoroHomeScreenState();
}

class _PomodoroHomeScreenState extends State<PomodoroHomeScreen> {
  // Storage keys
  static const String _tasksKey = 'minimalist_focus_tasks_v5';
  static const String _presetIndexKey = 'minimalist_focus_preset_idx';
  static const String _autoBreakKey = 'minimalist_focus_auto_break';
  static const String _soundEnabledKey = 'minimalist_focus_ambient_sound';
  static const String _dailyGoalKey = 'minimalist_focus_daily_goal_mins';
  static const String _todayDateKey = 'minimalist_focus_today_date';
  static const String _todayMinutesKey = 'minimalist_focus_today_mins';
  static const String _historyMapKey = 'minimalist_focus_history_map';
  static const String _customFocusKey = 'minimalist_focus_custom_f';
  static const String _customShortKey = 'minimalist_focus_custom_s';
  static const String _customLongKey = 'minimalist_focus_custom_l';
  static const String _themeModeKey = 'minimalist_focus_theme_mode';
  static const String _compactTrayKey = 'minimalist_focus_compact_tray';

  // Settings & State
  int _selectedPresetIndex = 0;
  bool _autoStartBreaks = false;
  bool _ambientSoundEnabled = false;
  bool _compactTrayMode = false;
  int _dailyGoalMinutes = 120;
  int _todayFocusedMinutes = 0;
  Map<String, int> _weeklyHistory = {};
  int _completedCycleSessions = 0;

  // Custom durations state
  int _customFocusMins = 30;
  int _customShortMins = 5;
  int _customLongMins = 15;

  TimerPhase _phase = TimerPhase.focus;
  late int _remainingSeconds;
  bool _isRunning = false;
  Timer? _timer;

  final AudioPlayer _audioPlayer = AudioPlayer();

  // Task Queue State
  List<StudyTask> _tasks = [];
  bool _isLoading = true;
  int _newTaskEstimate = 1;
  String _newTaskCategory = 'General';
  final TextEditingController _taskController = TextEditingController();

  final List<String> _availableCategories = ['General', 'University', 'Coding', 'Security'];

  // Health break tips
  final List<String> _healthTips = [
    'Drink a glass of water to stay hydrated 💧',
    'Look 20 feet away at something for 20 seconds 👁️',
    'Stand up, stretch your arms, and roll your shoulders 🧘',
    'Take 3 deep, slow breaths to reset your focus 🍃',
  ];
  String _currentHealthTip = '';

  TimerPreset get _currentPreset {
    if (_selectedPresetIndex == 3) {
      return TimerPreset(
        name: 'Custom',
        focusMinutes: _customFocusMins,
        shortBreakMinutes: _customShortMins,
        longBreakMinutes: _customLongMins,
      );
    }
    return kBasePresets[_selectedPresetIndex];
  }

  int get _currentPhaseDurationSeconds {
    switch (_phase) {
      case TimerPhase.focus:
        return _currentPreset.focusMinutes * 60;
      case TimerPhase.shortBreak:
        return _currentPreset.shortBreakMinutes * 60;
      case TimerPhase.longBreak:
        return _currentPreset.longBreakMinutes * 60;
    }
  }

  @override
  void initState() {
    super.initState();
    _remainingSeconds = kBasePresets[0].focusMinutes * 60;
    _currentHealthTip = _healthTips[Random().nextInt(_healthTips.length)];
    _loadAllData();
  }

  String _getTodayDateString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadAllData() async {
    final prefs = await SharedPreferences.getInstance();

    final savedPresetIdx = prefs.getInt(_presetIndexKey) ?? 0;
    final savedAutoBreak = prefs.getBool(_autoBreakKey) ?? false;
    final savedAmbient = prefs.getBool(_soundEnabledKey) ?? false;
    final savedGoal = prefs.getInt(_dailyGoalKey) ?? 120;
    _compactTrayMode = prefs.getBool(_compactTrayKey) ?? false;

    _customFocusMins = prefs.getInt(_customFocusKey) ?? 30;
    _customShortMins = prefs.getInt(_customShortKey) ?? 5;
    _customLongMins = prefs.getInt(_customLongKey) ?? 15;

    final String? themeStr = prefs.getString(_themeModeKey);
    if (themeStr != null && mounted) {
      if (themeStr == 'oled') FocusTimerApp.setThemeMode(context, AppThemeMode.oled);
      if (themeStr == 'midnight') FocusTimerApp.setThemeMode(context, AppThemeMode.midnight);
    }

    final String? historyJson = prefs.getString(_historyMapKey);
    if (historyJson != null) {
      final Map<String, dynamic> decoded = jsonDecode(historyJson);
      _weeklyHistory = decoded.map((key, value) => MapEntry(key, value as int));
    }

    final todayStr = _getTodayDateString();
    final savedDate = prefs.getString(_todayDateKey);
    int todayMins = 0;
    if (savedDate == todayStr) {
      todayMins = prefs.getInt(_todayMinutesKey) ?? 0;
    } else {
      await prefs.setString(_todayDateKey, todayStr);
      await prefs.setInt(_todayMinutesKey, 0);
    }
    _weeklyHistory[todayStr] = todayMins;

    final String? rawJson = prefs.getString(_tasksKey);
    List<StudyTask> loadedTasks;
    if (rawJson != null) {
      final List<dynamic> decoded = jsonDecode(rawJson) as List<dynamic>;
      loadedTasks = decoded.map((item) => StudyTask.fromMap(item as Map<String, dynamic>)).toList();
    } else {
      loadedTasks = [
        StudyTask(id: '1', title: 'Review lecture notes', estimatedPomodoros: 2, category: 'University'),
        StudyTask(id: '2', title: 'Refactor app state architecture', estimatedPomodoros: 3, category: 'Coding'),
      ];
    }

    setState(() {
      _selectedPresetIndex = savedPresetIdx.clamp(0, 3);
      _autoStartBreaks = savedAutoBreak;
      _ambientSoundEnabled = savedAmbient;
      _dailyGoalMinutes = savedGoal;
      _todayFocusedMinutes = todayMins;
      _tasks = loadedTasks;
      _remainingSeconds = _currentPhaseDurationSeconds;
      _isLoading = false;
    });

    if (rawJson == null) await _saveTasks();
  }

  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_tasks.map((t) => t.toMap()).toList());
    await prefs.setString(_tasksKey, encoded);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetIndexKey, _selectedPresetIndex);
    await prefs.setBool(_autoBreakKey, _autoStartBreaks);
    await prefs.setBool(_soundEnabledKey, _ambientSoundEnabled);
    await prefs.setInt(_dailyGoalKey, _dailyGoalMinutes);
    await prefs.setInt(_customFocusKey, _customFocusMins);
    await prefs.setInt(_customShortKey, _customShortMins);
    await prefs.setInt(_customLongKey, _customLongMins);
    await prefs.setBool(_compactTrayKey, _compactTrayMode);

    String tName = 'dark';
    if (widget.currentTheme == AppThemeMode.oled) tName = 'oled';
    if (widget.currentTheme == AppThemeMode.midnight) tName = 'midnight';
    await prefs.setString(_themeModeKey, tName);
  }

  Future<void> _recordFocusMinutes(int minutesAdded) async {
    final prefs = await SharedPreferences.getInstance();
    final todayStr = _getTodayDateString();

    final int updatedMinutes = _todayFocusedMinutes + minutesAdded;
    _weeklyHistory[todayStr] = updatedMinutes;

    await prefs.setString(_todayDateKey, todayStr);
    await prefs.setInt(_todayMinutesKey, updatedMinutes);
    await prefs.setString(_historyMapKey, jsonEncode(_weeklyHistory));

    setState(() {
      _todayFocusedMinutes = updatedMinutes;
    });
  }

  StudyTask? get _activeTask {
    for (final task in _tasks) {
      if (!task.isCompleted) return task;
    }
    return null;
  }

  double get _progress {
    final int total = _currentPhaseDurationSeconds;
    if (total == 0) return 0;
    return _remainingSeconds / total;
  }

  double get _dailyGoalProgress {
    if (_dailyGoalMinutes <= 0) return 1.0;
    return (_todayFocusedMinutes / _dailyGoalMinutes).clamp(0.0, 1.0);
  }

  String get _formattedTime {
    final int minutes = _remainingSeconds ~/ 60;
    final int seconds = _remainingSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String get _formattedTodayTime {
    if (_todayFocusedMinutes < 60) {
      return '${_todayFocusedMinutes}m';
    }
    final int hours = _todayFocusedMinutes ~/ 60;
    final int mins = _todayFocusedMinutes % 60;
    return mins == 0 ? '${hours}h' : '${hours}h ${mins}m';
  }

  void _updateBrowserTabTitle() {
    // Cross-platform safe stub (avoids dart:html dependency on mobile builds)
  }

  void _playAlarmSound() {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
  }

  void _toggleTimer() {
    if (_isRunning) {
      _pauseTimer();
    } else {
      _startTimer();
    }
  }

  void _startTimer() {
    setState(() => _isRunning = true);
    WakepointManager.activate();

    if (_ambientSoundEnabled && _phase == TimerPhase.focus) {
      _playAmbientNoise();
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds > 0) {
        setState(() => _remainingSeconds--);
        _updateBrowserTabTitle();
      } else {
        _handleSessionComplete();
      }
    });
  }

  Future<void> _playAmbientNoise() async {
    try {
      await _audioPlayer.setSource(UrlSource('https://actions.google.com/sounds/v1/weather/rain_heavy_loud.ogg'));
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.resume();
    } catch (_) {}
  }

  void _stopAmbientNoise() {
    _audioPlayer.stop();
  }

  Future<void> _handleSessionComplete() async {
    final bool finishedFocus = _phase == TimerPhase.focus;
    _pauseTimer();
    _playAlarmSound();

    TimerPhase nextPhase;
    String bannerMessage;

    if (finishedFocus) {
      if (_activeTask != null) {
        setState(() => _activeTask!.pomodorosCompleted++);
        await _saveTasks();
      }
      await _recordFocusMinutes(_currentPreset.focusMinutes);

      _completedCycleSessions++;
      if (_completedCycleSessions >= 4) {
        _completedCycleSessions = 0;
        nextPhase = TimerPhase.longBreak;
        bannerMessage = '4 blocks complete! Enjoy a ${_currentPreset.longBreakMinutes}m long break.';
      } else {
        nextPhase = TimerPhase.shortBreak;
        bannerMessage = 'Focus block complete! Take a ${_currentPreset.shortBreakMinutes}m break.';
      }
      setState(() {
        _currentHealthTip = _healthTips[Random().nextInt(_healthTips.length)];
      });
    } else {
      nextPhase = TimerPhase.focus;
      bannerMessage = 'Break over! Ready for your next focus session.';
    }

    _switchPhase(nextPhase);

    if (finishedFocus && _autoStartBreaks) {
      _startTimer();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _getAccentColor(nextPhase).withValues(alpha: 0.4)),
        ),
        content: Text(bannerMessage, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  void _pauseTimer() {
    _timer?.cancel();
    _stopAmbientNoise();
    WakepointManager.deactivate();
    setState(() => _isRunning = false);
  }

  void _resetTimer() {
    _pauseTimer();
    setState(() {
      _remainingSeconds = _currentPhaseDurationSeconds;
    });
  }

  void _skipSession() {
    _pauseTimer();
    if (_phase == TimerPhase.focus) {
      _switchPhase(TimerPhase.shortBreak);
    } else {
      _switchPhase(TimerPhase.focus);
    }
  }

  void _switchPhase(TimerPhase newPhase) {
    _pauseTimer();
    setState(() {
      _phase = newPhase;
      _remainingSeconds = _currentPhaseDurationSeconds;
    });
  }

  void _addTask(String rawTitle) {
    final title = rawTitle.trim();
    if (title.isEmpty) return;

    setState(() {
      _tasks.add(
        StudyTask(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          estimatedPomodoros: _newTaskEstimate,
          category: _newTaskCategory,
        ),
      );
      _newTaskEstimate = 1;
    });
    _taskController.clear();
    _saveTasks();
  }

  void _toggleTaskDone(StudyTask task) {
    setState(() {
      task.isCompleted = !task.isCompleted;
    });
    _saveTasks();
  }

  void _deleteTask(String id) {
    setState(() {
      _tasks.removeWhere((task) => task.id == id);
    });
    _saveTasks();
  }

  void _clearCompletedTasks() {
    setState(() {
      _tasks.removeWhere((task) => task.isCompleted);
    });
    _saveTasks();
  }

  void _reorderTasks(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final StudyTask movedTask = _tasks.removeAt(oldIndex);
      _tasks.insert(newIndex, movedTask);
    });
    _saveTasks();
  }

  // Edit Task & Notes Dialog
  void _editTaskDialog(StudyTask task) {
    final TextEditingController editController = TextEditingController(text: task.title);
    final TextEditingController notesController = TextEditingController(text: task.notes);
    int tempEstimate = task.estimatedPomodoros;
    String tempCategory = task.category;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Edit Task & Session Notes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Task Title', style: TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: editController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Category', style: TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: _availableCategories.contains(tempCategory) ? tempCategory : 'General',
                      dropdownColor: Theme.of(context).colorScheme.surface,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                      items: _availableCategories.map((cat) {
                        return DropdownMenuItem(value: cat, child: Text(cat, style: const TextStyle(fontSize: 14)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => tempCategory = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text('Session Notes / Logbook', style: TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: notesController,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Jot down thoughts or progress milestones...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Estimated Pomodoros:', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, size: 20),
                              onPressed: () {
                                if (tempEstimate > 1) setDialogState(() => tempEstimate--);
                              },
                            ),
                            Text('$tempEstimate', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline, size: 20),
                              onPressed: () {
                                if (tempEstimate < 10) setDialogState(() => tempEstimate++);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF64FFDA), foregroundColor: Colors.black),
                  onPressed: () {
                    final newTitle = editController.text.trim();
                    if (newTitle.isNotEmpty) {
                      setState(() {
                        task.title = newTitle;
                        task.category = tempCategory;
                        task.notes = notesController.text.trim();
                        task.estimatedPomodoros = tempEstimate;
                      });
                      _saveTasks();
                    }
                    Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Weekly Stats Modal Sheet
  void _openStatsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        final now = DateTime.now();
        List<String> last7Days = [];
        for (int i = 6; i >= 0; i--) {
          final day = now.subtract(Duration(days: i));
          last7Days.add('${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}');
        }

        int maxMins = 60;
        for (var dateStr in last7Days) {
          final mins = _weeklyHistory[dateStr] ?? 0;
          if (mins > maxMins) maxMins = mins;
        }

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              const Text('WEEKLY FOCUS STATS', style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: last7Days.map((dateStr) {
                  final mins = _weeklyHistory[dateStr] ?? 0;
                  final double heightRatio = (mins / maxMins).clamp(0.1, 1.0);
                  final dayLabel = DateTime.parse(dateStr).toLocal().toString().split(' ')[0].substring(5);

                  return Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${mins}m', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                      const SizedBox(height: 6),
                      Container(
                        width: 28,
                        height: heightRatio * 110,
                        decoration: BoxDecoration(
                          color: dateStr == _getTodayDateString() ? const Color(0xFF64FFDA) : const Color(0xFF2A2E39),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(dayLabel, style: const TextStyle(fontSize: 10, color: Colors.white38)),
                    ],
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Color _getAccentColor(TimerPhase phase) {
    switch (phase) {
      case TimerPhase.focus:
        return const Color(0xFF64FFDA);
      case TimerPhase.shortBreak:
        return const Color(0xFF82B1FF);
      case TimerPhase.longBreak:
        return const Color(0xFFB388FF);
    }
  }

  Color _getCategoryColor(String category) {
    switch (category) {
      case 'University':
        return const Color(0xFFFFAB40); // Orange
      case 'Coding':
        return const Color(0xFF64FFDA); // Teal
      case 'Security':
        return const Color(0xFFFF5252); // Red
      default:
        return const Color(0xFFE0E0E0); // Grey
    }
  }

  // Settings & Custom Durations Bottom Sheet
  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final accent = _getAccentColor(_phase);
            List<TimerPreset> displayPresets = [
              ...kBasePresets,
              TimerPreset(name: 'Custom', focusMinutes: _customFocusMins, shortBreakMinutes: _customShortMins, longBreakMinutes: _customLongMins)
            ];

            return Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 32),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('APPEARANCE & THEME', style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildThemeButton('Dark', AppThemeMode.dark, widget.currentTheme == AppThemeMode.dark, setModalState),
                        const SizedBox(width: 8),
                        _buildThemeButton('OLED', AppThemeMode.oled, widget.currentTheme == AppThemeMode.oled, setModalState),
                        const SizedBox(width: 8),
                        _buildThemeButton('Midnight', AppThemeMode.midnight, widget.currentTheme == AppThemeMode.midnight, setModalState),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('TIMER PRESETS', style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    ...List.generate(displayPresets.length, (index) {
                      final preset = displayPresets[index];
                      final isSelected = _selectedPresetIndex == index;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedPresetIndex = index;
                            _pauseTimer();
                            _remainingSeconds = _currentPhaseDurationSeconds;
                          });
                          setModalState(() {});
                          _saveSettings();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? accent.withValues(alpha: 0.12) : Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isSelected ? accent : Colors.white10),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(preset.name, style: TextStyle(fontWeight: FontWeight.w600, color: isSelected ? accent : Colors.white)),
                              Text('${preset.focusMinutes}m / ${preset.shortBreakMinutes}m / ${preset.longBreakMinutes}m', style: const TextStyle(fontSize: 13, color: Colors.white54)),
                            ],
                          ),
                        ),
                      );
                    }),
                    if (_selectedPresetIndex == 3) ...[
                      const SizedBox(height: 12),
                      const Text('CUSTOM DURATIONS (MINUTES)', style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.white38)),
                      const SizedBox(height: 8),
                      _buildSliderRow('Focus', _customFocusMins, 5, 90, (val) {
                        setModalState(() => _customFocusMins = val.toInt());
                        setState(() => _remainingSeconds = _currentPhaseDurationSeconds);
                        _saveSettings();
                      }, accent),
                      _buildSliderRow('Short Break', _customShortMins, 1, 20, (val) {
                        setModalState(() => _customShortMins = val.toInt());
                        _saveSettings();
                      }, accent),
                      _buildSliderRow('Long Break', _customLongMins, 5, 40, (val) {
                        setModalState(() => _customLongMins = val.toInt());
                        _saveSettings();
                      }, accent),
                    ],
                    const SizedBox(height: 12),
                    const Text('DAILY GOAL', style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.white38)),
                    _buildSliderRow('Target', _dailyGoalMinutes, 30, 360, (val) {
                      setModalState(() => _dailyGoalMinutes = val.toInt());
                      setState(() {});
                      _saveSettings();
                    }, accent, step: 30, unit: 'm'),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-start breaks', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      activeThumbColor: accent,
                      value: _autoStartBreaks,
                      onChanged: (val) {
                        setState(() => _autoStartBreaks = val);
                        setModalState(() {});
                        _saveSettings();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Ambient focus noise', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      activeThumbColor: accent,
                      value: _ambientSoundEnabled,
                      onChanged: (val) {
                        setState(() => _ambientSoundEnabled = val);
                        setModalState(() {});
                        _saveSettings();
                        if (!_ambientSoundEnabled) _stopAmbientNoise();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Simulate system tray mode', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: const Text('Minimizes focus footprint', style: TextStyle(fontSize: 11, color: Colors.white38)),
                      activeThumbColor: accent,
                      value: _compactTrayMode,
                      onChanged: (val) {
                        setState(() => _compactTrayMode = val);
                        setModalState(() {});
                        _saveSettings();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThemeButton(String label, AppThemeMode mode, bool isSelected, StateSetter setModalState) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          FocusTimerApp.setThemeMode(context, mode);
          setModalState(() {});
          _saveSettings();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF64FFDA).withValues(alpha: 0.15) : Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isSelected ? const Color(0xFF64FFDA) : Colors.white10),
          ),
          child: Center(
            child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isSelected ? const Color(0xFF64FFDA) : Colors.white60)),
          ),
        ),
      ),
    );
  }

  Widget _buildSliderRow(String label, int value, double min, double max, ValueChanged<double> onChanged, Color accent, {int step = 1, String unit = 'm'}) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70))),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: min,
            max: max,
            divisions: ((max - min) / step).toInt(),
            activeColor: accent,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 45, child: Text('$value$unit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: accent))),
      ],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _audioPlayer.dispose();
    _taskController.dispose();
    WakepointManager.deactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accentColor = _getAccentColor(_phase);
    final StudyTask? currentTask = _activeTask;
    final bool hasCompletedTasks = _tasks.any((t) => t.isCompleted);

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 135,
        leading: Center(
          child: GestureDetector(
            onTap: _openStatsSheet,
            child: Container(
              margin: const EdgeInsets.only(left: 16),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accentColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      value: _dailyGoalProgress,
                      strokeWidth: 2.5,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formattedTodayTime,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
        title: Text(_compactTrayMode ? 'MINI FOCUS' : 'FOCUS', style: const TextStyle(letterSpacing: 4, fontWeight: FontWeight.w600)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white70),
            tooltip: 'Timer Settings',
            onPressed: _openSettingsSheet,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: _compactTrayMode ? 380 : 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              children: [
                // 3-Mode Switcher Pills
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildModePill('Focus ${_currentPreset.focusMinutes}m', _phase == TimerPhase.focus, () => _switchPhase(TimerPhase.focus), accentColor),
                    const SizedBox(width: 8),
                    _buildModePill('Break ${_currentPreset.shortBreakMinutes}m', _phase == TimerPhase.shortBreak, () => _switchPhase(TimerPhase.shortBreak), accentColor),
                    const SizedBox(width: 8),
                    _buildModePill('Long ${_currentPreset.longBreakMinutes}m', _phase == TimerPhase.longBreak, () => _switchPhase(TimerPhase.longBreak), accentColor),
                  ],
                ),
                const SizedBox(height: 18),

                // Active Task / Health Tip Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _phase == TimerPhase.focus
                            ? 'WORKING ON  •  CYCLE ${_completedCycleSessions + 1}/4'
                            : (_phase == TimerPhase.longBreak ? 'LONG RECHARGE' : 'SHORT BREAK TIP'),
                        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: accentColor, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _phase != TimerPhase.focus ? _currentHealthTip : (currentTask?.title ?? 'All tasks completed!'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Circular Progress Ring + Countdown Display
                SizedBox(
                  width: 205,
                  height: 205,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 205,
                        height: 205,
                        child: CircularProgressIndicator(
                          value: _progress,
                          strokeWidth: 6,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _formattedTime,
                            style: TextStyle(
                              fontSize: 50,
                              fontWeight: FontWeight.w200,
                              color: accentColor,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            _isRunning ? 'IN PROGRESS' : 'PAUSED',
                            style: const TextStyle(fontSize: 10, letterSpacing: 2.5, color: Colors.white38),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Control Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _toggleTimer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentColor,
                        foregroundColor: const Color(0xFF0F1115),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                      icon: Icon(_isRunning ? Icons.pause : Icons.play_arrow),
                      label: Text(_isRunning ? 'PAUSE' : 'START', style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _resetTimer,
                      tooltip: 'Reset Timer',
                      style: IconButton.styleFrom(
                        padding: const EdgeInsets.all(14),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                      ),
                      icon: const Icon(Icons.refresh),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _skipSession,
                      tooltip: 'Skip Phase',
                      style: IconButton.styleFrom(
                        padding: const EdgeInsets.all(14),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                      ),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Task Queue Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('TASK QUEUE', style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        if (hasCompletedTasks)
                          GestureDetector(
                            onTap: _clearCompletedTasks,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text('Clear done', style: TextStyle(fontSize: 12, color: accentColor, fontWeight: FontWeight.w500)),
                            ),
                          ),
                        Text('${_tasks.where((t) => !t.isCompleted).length} remaining', style: const TextStyle(fontSize: 12, color: Colors.white38)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Add Task Input & Category Selector
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _taskController,
                        onSubmitted: _addTask,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Add a study task...',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Category dropdown popup button
                    PopupMenuButton<String>(
                      initialValue: _newTaskCategory,
                      color: Theme.of(context).colorScheme.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      onSelected: (val) => setState(() => _newTaskCategory = val),
                      itemBuilder: (context) => _availableCategories.map((cat) {
                        return PopupMenuItem(
                          value: cat,
                          child: Row(
                            children: [
                              Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: _getCategoryColor(cat))),
                              const SizedBox(width: 8),
                              Text(cat, style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        );
                      }).toList(),
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Center(
                          child: Icon(Icons.label_outline, size: 20, color: _getCategoryColor(_newTaskCategory)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _newTaskEstimate = (_newTaskEstimate % 4) + 1;
                        });
                      },
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$_newTaskEstimate', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accentColor)),
                            const Text('EST', style: TextStyle(fontSize: 9, color: Colors.white38)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Task List with Tags and Session Notes indicators
                Expanded(
                  child: _isLoading
                      ? Center(child: CircularProgressIndicator(color: accentColor))
                      : _tasks.isEmpty
                      ? const Center(
                    child: Text(
                      'Your queue is empty.\nAdd a task above to start focusing.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, height: 1.5),
                    ),
                  )
                      : ReorderableListView.builder(
                    itemCount: _tasks.length,
                    onReorder: _reorderTasks,
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) {
                      return Material(color: Colors.transparent, elevation: 6, borderRadius: BorderRadius.circular(12), child: child);
                    },
                    itemBuilder: (context, index) {
                      final task = _tasks[index];
                      final bool isCurrent = currentTask?.id == task.id && _phase == TimerPhase.focus;
                      final Color catColor = _getCategoryColor(task.category);

                      return Container(
                        key: ValueKey(task.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isCurrent ? accentColor.withValues(alpha: 0.5) : Colors.transparent),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.only(left: 8, right: 4),
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Icon(Icons.drag_indicator, size: 20, color: Colors.white24),
                                ),
                              ),
                              Checkbox(
                                value: task.isCompleted,
                                activeColor: accentColor,
                                checkColor: Theme.of(context).scaffoldBackgroundColor,
                                onChanged: (_) => _toggleTaskDone(task),
                              ),
                            ],
                          ),
                          title: GestureDetector(
                            onTap: () => _editTaskDialog(task),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    task.title,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: task.isCompleted ? Colors.white38 : Colors.white,
                                      decoration: task.isCompleted ? TextDecoration.lineThrough : TextDecoration.none,
                                    ),
                                  ),
                                ),
                                // Category Badge Tag
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: catColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: catColor.withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    task.category,
                                    style: TextStyle(fontSize: 10, color: catColor, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                ...List.generate(task.estimatedPomodoros.clamp(1, 6), (dotIdx) {
                                  final bool filled = dotIdx < task.pomodorosCompleted;
                                  return Container(
                                    width: 7,
                                    height: 7,
                                    margin: const EdgeInsets.only(right: 4),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: filled ? accentColor : Colors.white.withValues(alpha: 0.15),
                                    ),
                                  );
                                }),
                                const SizedBox(width: 4),
                                Text('${task.pomodorosCompleted}/${task.estimatedPomodoros}', style: const TextStyle(fontSize: 11, color: Colors.white38)),
                                if (task.notes.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.notes, size: 13, color: Colors.white54),
                                ],
                              ],
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Colors.white38),
                            onPressed: () => _deleteTask(task.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModePill(String label, bool isSelected, VoidCallback onTap, Color accentColor) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: isSelected ? accentColor : Colors.white12, width: 1.2),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: isSelected ? accentColor : Colors.white60, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal),
        ),
      ),
    );
  }
}

class WakepointManager {
  static void activate() {
    try {
      WakepointManagerPlatform.enable();
    } catch (_) {}
  }

  static void deactivate() {
    try {
      WakepointManagerPlatform.disable();
    } catch (_) {}
  }
}

class WakepointManagerPlatform {
  static void enable() {
    WakelockPlus.enable();
  }

  static void disable() {
    WakelockPlus.disable();
  }
}