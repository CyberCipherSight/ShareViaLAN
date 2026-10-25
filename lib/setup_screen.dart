import 'package:flutter/material.dart';

import 'battery_optimization_helper.dart';

class SetupScreen extends StatefulWidget {
  final Future<void> Function(String name, bool rememberName) onNameSet;

  const SetupScreen({
    super.key,
    required this.onNameSet,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _rememberName = true;
  bool _isSaving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _isSaving) {
      return;
    }
    setState(() => _isSaving = true);
    await widget.onNameSet(name, _rememberName);
    if (mounted) {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.wifi_tethering,
                  size: 64,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Share files locally',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'What should others see you as?',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                const BatteryOptimizationBanner(
                  reason: BatteryOptimizationPromptReason.setup,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: 'Enter your name...',
                    filled: true,
                    fillColor: const Color(0xFF071827),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _confirm(),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _rememberName,
                  onChanged: (value) {
                    setState(() => _rememberName = value ?? true);
                  },
                  title: const Text('Remember my username'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  activeColor: Colors.lightBlueAccent,
                  checkColor: Colors.black,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlueAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _isSaving ? null : _confirm,
                    child: _isSaving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'Let me in',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
