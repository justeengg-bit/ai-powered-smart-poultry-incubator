import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Onboarding Dialog
// ─────────────────────────────────────────────────────────────────────────────
class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  int _page = 0;

  static const _steps = [
    _OnboardStep(
      icon: Icons.wifi,
      color: Color(0xFF2979FF),
      title: 'Connect to Incubator WiFi',
      body:
          'Go to your phone\'s WiFi settings and connect to '
          '"AI_CANDLING" (password: thesis123). The camera stream '
          'will start automatically once connected.',
    ),
    _OnboardStep(
      icon: Icons.tune,
      color: Color(0xFF00E676),
      title: 'Calibrate the Grid',
      body:
          'Tap the Grid tab (bottom nav) or the tune icon in the '
          'toolbar. Select individual boundary lines and use the D-pad '
          'to align the grid with your physical egg tray. Tap '
          '"Save & Apply" when done.',
    ),
    _OnboardStep(
      icon: Icons.camera_alt,
      color: Color(0xFFFFD54F),
      title: 'Capture & Analyze',
      body:
          'Dim the room lights and press "CAPTURE & ANALYZE". The AI '
          'will photograph each egg slot and classify it as Fertile or '
          'Infertile. Results appear on the grid below the camera.',
    ),
    _OnboardStep(
      icon: Icons.history,
      color: Color(0xFFFF5252),
      title: 'Review & Export',
      body:
          'All scans are saved in the History tab with charts, trend '
          'lines, and your thesis data log. Open any session and tap '
          'the print icon to generate a PDF report you can share or '
          'print.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final step = _steps[_page];
    final isLast = _page == _steps.length - 1;

    return AlertDialog(
      backgroundColor: const Color(0xFF161B2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.all(24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              _steps.length,
              (i) => Container(
                width: i == _page ? 20 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == _page ? step.color : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: step.color.withAlpha(30),
              shape: BoxShape.circle,
              border: Border.all(color: step.color, width: 2),
            ),
            child: Icon(step.icon, color: step.color, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            step.title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            step.body,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (_page > 0)
                TextButton(
                  onPressed: () => setState(() => _page--),
                  child: const Text('Back'),
                )
              else
                const SizedBox(width: 60),
              ElevatedButton(
                onPressed: isLast
                    ? () => Navigator.pop(context)
                    : () => setState(() => _page++),
                style: ElevatedButton.styleFrom(
                  backgroundColor: step.color,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(isLast ? 'Get Started' : 'Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OnboardStep {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  const _OnboardStep({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
}
