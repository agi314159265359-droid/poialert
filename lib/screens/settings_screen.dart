import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/colors.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _alertDistance = 150;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  bool _backgroundTracking = true;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _alertDistance =
          (prefs.getDouble('alert_distance') ?? 150.0).clamp(50.0, 500.0);
      _soundEnabled = prefs.getBool('sound_enabled') ?? true;
      _vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      _backgroundTracking = prefs.getBool('background_tracking') ?? true;
      _isLoading = false;
    });
  }

  Future<void> _saveAlertDistance(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('alert_distance', value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Alert Distance
          const Text(
            'Alert Settings',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Alert Distance',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${_alertDistance.toInt()}m',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _alertDistance,
                    min: 50,
                    max: 500,
                    divisions: 9,
                    activeColor: AppColors.primary,
                    onChanged: (value) {
                      setState(() => _alertDistance = value);
                    },
                    onChangeEnd: (value) {
                      _saveAlertDistance(value);
                    },
                  ),
                  Text(
                    'You will be alerted when within ${_alertDistance.toInt()} meters of a POI',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Notification Settings
          const Text(
            'Notification Settings',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Sound Alerts'),
                  subtitle: const Text('Play sound when alert triggers'),
                  value: _soundEnabled,
                  activeColor: AppColors.primary,
                  onChanged: (value) {
                    setState(() => _soundEnabled = value);
                    _saveBool('sound_enabled', value);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Vibration'),
                  subtitle: const Text('Vibrate on alert'),
                  value: _vibrationEnabled,
                  activeColor: AppColors.primary,
                  onChanged: (value) {
                    setState(() => _vibrationEnabled = value);
                    _saveBool('vibration_enabled', value);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Location Settings
          const Text(
            'Location Settings',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: SwitchListTile(
              title: const Text('Background Tracking'),
              subtitle: const Text('Track location when app is closed'),
              value: _backgroundTracking,
              activeColor: AppColors.primary,
              onChanged: (value) {
                setState(() => _backgroundTracking = value);
                _saveBool('background_tracking', value);
              },
            ),
          ),

          const SizedBox(height: 32),

          // About Section
          const Text(
            'About',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Version'),
                  subtitle: Text('1.1.0 (Supabase)'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Terms of Service'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}