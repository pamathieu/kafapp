// ── Date formatting — call this everywhere a date needs to display ──────────
  //
  // Handles two raw formats from the DB / API:
  //   ISO:   "2026-04-14"
  //   Slash: "09 / 03 / 2026"  (DD / MM / YYYY, stored by old certificate flow)
  //
  // Output per locale:
  //   en  → April 14, 2026
  //   fr  → 14 Avril 2026
  //   ht  → 14 Avril 2026   (Kreyol uses French month names)
  //   es  → 14 de Abril de 2026
  //   pt  → 14 de Abril de 2026
  // ───────────────────────────────────────────────────────────────────────────

class AppStringsFormatDate {
  static String formatDate(String raw, String locale) {
    if (raw.isEmpty || raw == '—') return raw;
    try {
      // Normalise slash format: "09 / 03 / 2026" → "2026-03-09"
      final cleaned = raw.replaceAll(' ', '');
      String iso = raw.trim();
      if (cleaned.contains('/')) {
        final p = cleaned.split('/');
        if (p.length == 3) {
          iso = '${p[2]}-${p[1].padLeft(2, '0')}-${p[0].padLeft(2, '0')}';
        }
      }

      final parts = iso.split('-');
      if (parts.length != 3) return raw;
      final y = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final d = int.tryParse(parts[2]) ?? 0;
      if (y == 0 || m == 0 || d == 0) return raw;

      const _en = [
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      // French names shared by fr and ht (Haitian Creole)
      const _fr = [
        '', 'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
        'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre',
      ];
      const _es = [
        '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
        'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
      ];
      const _pt = [
        '', 'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
        'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro',
      ];

      switch (locale) {
        case 'en':
          return '${_en[m]} $d, $y';
        case 'es':
          return '$d de ${_es[m]} de $y';
        case 'pt':
          return '$d de ${_pt[m]} de $y';
        case 'fr':
        case 'ht':
        default:
          return '$d ${_fr[m]} $y';
      }
    } catch (_) {
      return raw;
    }
  }
}