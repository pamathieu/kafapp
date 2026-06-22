import 'package:flutter/material.dart';
import '../misc/app_strings.dart';

const _green = Color(0xFF1A5C2A);

/// Monthly / Annual billing frequency toggle.
/// Shared between the Plans screen and the Quick Quote simulator.
class BillingToggle extends StatelessWidget {
  final bool annual;
  final String locale;
  final ValueChanged<bool> onChanged;

  const BillingToggle({
    super.key,
    required this.annual,
    required this.locale,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);

    Widget segment(String label, bool isAnnual) {
      final selected = annual == isAnnual;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(isAnnual),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? _green : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.white : Colors.grey.shade600)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        segment(s('billingMonthly'), false),
        segment(s('billingAnnual'), true),
      ]),
    );
  }
}
