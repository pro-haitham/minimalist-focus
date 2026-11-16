import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// Conditional import for setting web document title safely
import 'dart:html' as html;

void main() {
  runApp(const FocusTimerApp());
}

enum TimerPhase { focus, shortBreak, longBreak }

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

// Base presets (index 3 is reserved for custom user configuration)
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

  StudyTask({
    required this.id,
    required this.title,
    this.isCompleted = false,
    this.pomodorosCompleted = 0,
    this.estimatedPomodoros = 1,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'isCompleted': isCompleted,
      'pomodorosCompleted': pomodorosCompleted,
      'estimatedPomodoros': estimatedPomodoros,
    };
  }

  factory StudyTask.fromMap(Map<String, dynamic> map) {
    return StudyTask(
      id: map['id'] as String,
      title: map['title'] as String,
      isCompleted: map['isCompleted'] as bool? ?? false,
      pomodorosCompleted: map['pomodorosCompleted'] as int? ?? 0,
      estimatedPomodoros: map['estimatedPomodoros'] as int? ?? 1,
    );
  }
}

class FocusTimerApp extends StatelessWidget {
  const FocusTimerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Minimalist Focus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF64FFDA),
          surface: Color(0xFF181B20),
        ),
      ),
      home: const PomodoroHomeScreen(),
    );
  }
}

class PomodoroHomeScreen extends StatefulWidget {
  const PomodoroHomeScreen({super.key});

  @override
  State<PomodoroHomeScreen> createState() => _PomodoroHomeScreenState();
}

class _PomodoroHomeScreenState extends State<PomodoroHomeScreen> {
  // Storage keys
  static const String _tasksKey = 'minimalist_focus_tasks_v3';
  static const String _presetIndexKey = 'minimalist_focus_preset_idx';
  static const String _autoBreakKey = 'minimalist_focus_auto_break';
  static const String _soundEnabledKey = 'minimalist_focus_ambient_sound';
  static const String _todayDateKey = 'minimalist_focus_today_date';
  static const String _todayMinutesKey = 'minimalist_focus_today_mins';
  static const String _customFocusKey = 'minimalist_focus_custom_f';
  static const String _customShortKey = 'minimalist_focus_custom_s';
  static const String _customLongKey = 'minimalist_focus_custom_l';

  // Settings & State
  int _selectedPresetIndex = 0;
  bool _autoStartBreaks = false;
  bool _ambientSoundEnabled = false;
  int _todayFocusedMinutes = 0;
  int _completedCycleSessions = 0;

  // Custom preset minutes sliders state
  int _customFocusMins = 30;
  int _customShortMins = 5;
  int _customLongMins = 15;

  TimerPhase _phase = TimerPhase.focus;
  late int _remainingSeconds;
  bool _isRunning = false;
  Timer? _timer;

  // Audio player for ambient noise (using online brown noise looping generator stream)
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Task Queue State
  List<StudyTask> _tasks = [];
  bool _isLoading = true;
  int _newTaskEstimate = 1;
  final TextEditingController _taskController = TextEditingController();

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

    _customFocusMins = prefs.getInt(_customFocusKey) ?? 30;
    _customShortMins = prefs.getInt(_customShortKey) ?? 5;
    _customLongMins = prefs.getInt(_customLongKey) ?? 15;

    // Load today's focus minutes
    final todayStr = _getTodayDateString();
    final savedDate = prefs.getString(_todayDateKey);
    int todayMins = 0;
    if (savedDate == todayStr) {
      todayMins = prefs.getInt(_todayMinutesKey) ?? 0;
    } else {
      await prefs.setString(_todayDateKey, todayStr);
      await prefs.setInt(_todayMinutesKey, 0);
    }

    // Load tasks
    final String? rawJson = prefs.getString(_tasksKey);
    List<StudyTask> loadedTasks;
    if (rawJson != null) {
      final List<dynamic> decoded = jsonDecode(rawJson) as List<dynamic>;
      loadedTasks = decoded
          .map((item) => StudyTask.fromMap(item as Map<String, dynamic>))
          .toList();
    } else {
      loadedTasks = [
        StudyTask(id: '1', title: 'Review lecture notes', estimatedPomodoros: 2),
        StudyTask(id: '2', title: 'Complete practice problems', estimatedPomodoros: 3),
      ];
    }

    setState(() {
      _selectedPresetIndex = savedPresetIdx.clamp(0, 3);
      _autoStartBreaks = savedAutoBreak;
      _ambientSoundEnabled = savedAmbient;
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
    await prefs.setInt(_customFocusKey, _customFocusMins);
    await prefs.setInt(_customShortKey, _customShortMins);
    await prefs.setInt(_customLongKey, _customLongMins);
  }

  Future<void> _recordFocusMinutes(int minutesAdded) async {
    final prefs = await SharedPreferences.getInstance();
    final todayStr = _getTodayDateString();
    final savedDate = prefs.getString(_todayDateKey);

    final int updatedMinutes = (savedDate == todayStr ? _todayFocusedMinutes : 0) + minutesAdded;
    await prefs.setString(_todayDateKey, todayStr);
    await prefs.setInt(_todayMinutesKey, updatedMinutes);

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

  // Updates browser tab title on web dynamically
  void _updateBrowserTabTitle() {
    if (kIsWeb) {
      final taskName = _activeTask?.title ?? 'Focus';
      html.document.title = '($_formattedTime) $taskName';
    }
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
    WakepointManager.activate(); // Keep screen awake

    // Start ambient noise if enabled and in focus mode
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
      // Free public domain ambient brown noise loop stream
      await _audioPlayer.setSource(UrlSource('https://actions.google.com/sounds/v1/weather/rain_heavy_loud.ogg'));
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.resume();
    } catch (_) {
      // Fallback if network stream fails
    }
  }

  void _stopAmbientNoise() {
    _audioPlayer.stop();
  }

  Future<void> _handleSessionComplete() async {
    final bool finishedFocus = _phase == TimerPhase.focus;
    _pauseTimer();

    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.mediumImpact();

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
        backgroundColor: const Color(0xFF181B20),
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
    if (kIsWeb) html.document.title = 'Minimalist Focus';
  }

  void _resetTimer() {
    _pauseTimer();
    setState(() {
      _remainingSeconds = _currentPhaseDurationSeconds;
    });
    if (kIsWeb) html.document.title = 'Minimalist Focus';
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

  // Quick edit task dialog
  void _editTaskDialog(StudyTask task) {
    final TextEditingController editController = TextEditingController(text: task.title);
    int tempEstimate = task.estimatedPomodoros;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF181B20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Edit Task', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: editController,
                    autofocus: true,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF0F1115),
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
                              if (tempEstimate > 1) {
                                setDialogState(() => tempEstimate--);
                              }
                            },
                          ),
                          Text('$tempEstimate', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline, size: 20),
                            onPressed: () {
                              if (tempEstimate < 10) {
                                setDialogState(() => tempEstimate++);
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
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

  // Settings & Custom Durations Bottom Sheet
  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181B20),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final accent = _getAccentColor(_phase);
            List<TimerPreset> displayPresets = [...kBasePresets, TimerPreset(name: 'Custom', focusMinutes: _customFocusMins, shortBreakMinutes: _customShortMins, longBreakMinutes: _customLongMins)];

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
                    const Text(
                      'TIMER PRESETS',
                      style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600),
                    ),
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
                            color: isSelected ? accent.withValues(alpha: 0.12) : const Color(0xFF0F1115),
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
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-start breaks', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      subtitle: const Text('Automatically begin break when focus ends', style: TextStyle(fontSize: 12, color: Colors.white38)),
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
                      subtitle: const Text('Play subtle background rain during focus', style: TextStyle(fontSize: 12, color: Colors.white38)),
                      activeThumbColor: accent,
                      value: _ambientSoundEnabled,
                      onChanged: (val) {
                        setState(() => _ambientSoundEnabled = val);
                        setModalState(() {});
                        _saveSettings();
                        if (!_ambientSoundEnabled) _stopAmbientNoise();
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

  Widget _buildSliderRow(String label, int value, double min, double max, ValueChanged<double> onChanged, Color accent) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70))),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: min,
            max: max,
            divisions: (max - min).toInt(),
            activeColor: accent,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 35, child: Text('$value m', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: accent))),
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
        leadingWidth: 115,
        leading: Center(
          child: Container(
            margin: const EdgeInsets.only(left: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF181B20),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_fire_department, size: 14, color: accentColor),
                const SizedBox(width: 4),
                Text(
                  _formattedTodayTime,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        title: const Text(
          'FOCUS',
          style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.w600),
        ),
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
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              children: [
                // 3-Mode Switcher Pills
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildModePill(
                      'Focus ${_currentPreset.focusMinutes}m',
                      _phase == TimerPhase.focus,
                          () => _switchPhase(TimerPhase.focus),
                      accentColor,
                    ),
                    const SizedBox(width: 8),
                    _buildModePill(
                      'Break ${_currentPreset.shortBreakMinutes}m',
                      _phase == TimerPhase.shortBreak,
                          () => _switchPhase(TimerPhase.shortBreak),
                      accentColor,
                    ),
                    const SizedBox(width: 8),
                    _buildModePill(
                      'Long ${_currentPreset.longBreakMinutes}m',
                      _phase == TimerPhase.longBreak,
                          () => _switchPhase(TimerPhase.longBreak),
                      accentColor,
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // Active Task Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF181B20),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _phase == TimerPhase.focus
                            ? 'WORKING ON  •  CYCLE ${_completedCycleSessions + 1}/4'
                            : (_phase == TimerPhase.longBreak ? 'LONG RECHARGE' : 'SHORT BREAK'),
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.8,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _phase != TimerPhase.focus
                            ? 'Step away from the screen'
                            : (currentTask?.title ?? 'All tasks completed!'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
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
                            style: const TextStyle(
                              fontSize: 10,
                              letterSpacing: 2.5,
                              color: Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Control Buttons (Start/Pause, Reset, Skip)
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
                      label: Text(
                        _isRunning ? 'PAUSE' : 'START',
                        style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5),
                      ),
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
                      tooltip: 'Skip to Next Phase',
                      style: IconButton.styleFrom(
                        padding: const EdgeInsets.all(14),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                      ),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Task Queue Header + Clear Done
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'TASK QUEUE',
                      style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white54, fontWeight: FontWeight.w600),
                    ),
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
                        Text(
                          '${_tasks.where((t) => !t.isCompleted).length} remaining',
                          style: const TextStyle(fontSize: 12, color: Colors.white38),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Add Task Input Field + Estimate Selector
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
                          fillColor: const Color(0xFF181B20),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                          suffixIcon: IconButton(
                            icon: Icon(Icons.add_circle, color: accentColor),
                            onPressed: () => _addTask(_taskController.text),
                          ),
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF181B20),
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

                // Reorderable Task List
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
                      return Material(
                        color: Colors.transparent,
                        elevation: 6,
                        borderRadius: BorderRadius.circular(12),
                        child: child,
                      );
                    },
                    itemBuilder: (context, index) {
                      final task = _tasks[index];
                      final bool isCurrent = currentTask?.id == task.id && _phase == TimerPhase.focus;

                      return Container(
                        key: ValueKey(task.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF181B20),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isCurrent ? accentColor.withValues(alpha: 0.5) : Colors.transparent,
                          ),
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
                                checkColor: const Color(0xFF0F1115),
                                onChanged: (_) => _toggleTaskDone(task),
                              ),
                            ],
                          ),
                          title: GestureDetector(
                            onTap: () => _editTaskDialog(task),
                            child: Text(
                              task.title,
                              style: TextStyle(
                                fontSize: 14,
                                color: task.isCompleted ? Colors.white38 : Colors.white,
                                decoration: task.isCompleted ? TextDecoration.lineThrough : TextDecoration.none,
                              ),
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                ...List.generate(
                                  task.estimatedPomodoros.clamp(1, 6),
                                      (dotIdx) {
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
                                  },
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${task.pomodorosCompleted}/${task.estimatedPomodoros}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                                ),
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
          border: Border.all(
            color: isSelected ? accentColor : Colors.white12,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isSelected ? accentColor : Colors.white60,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// Helper utility for managing Android screen wake lock safely
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