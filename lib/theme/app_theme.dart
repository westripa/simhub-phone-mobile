import 'package:material_ui/material_ui.dart';

const _brand = Color(0xFF10B981);
const _brandLight = Color(0xFF059669);
const _darkBackground = Color(0xFF0C0D10);
const _darkPanel = Color(0xFF161920);
const _darkRail = Color(0xFF111318);
const _lightBackground = Color(0xFFFFFFFF);
const _lightPanel = Color(0xFFFAFAFA);
const _lightRail = Color(0xFFF4F4F5);

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(seedColor: _brand, brightness: brightness);
  final scheme = base.copyWith(
    primary: dark ? const Color(0xFF34D399) : _brandLight,
    onPrimary: dark ? const Color(0xFF052E16) : Colors.white,
    primaryContainer: dark ? const Color(0xFF123D2E) : const Color(0xFFD1FAE5),
    onPrimaryContainer: dark ? const Color(0xFFA7F3D0) : const Color(0xFF064E3B),
    surface: dark ? _darkBackground : _lightBackground,
    onSurface: dark ? const Color(0xFFF4F4F5) : const Color(0xFF09090B),
    surfaceContainerLowest: dark ? const Color(0xFF090A0D) : Colors.white,
    surfaceContainerLow: dark ? _darkRail : _lightRail,
    surfaceContainer: dark ? _darkPanel : _lightPanel,
    surfaceContainerHigh: dark ? const Color(0xFF1A1D24) : const Color(0xFFF4F4F5),
    surfaceContainerHighest: dark ? const Color(0xFF1F242D) : const Color(0xFFE4E4E7),
    onSurfaceVariant: dark ? const Color(0xFF9CA3AF) : const Color(0xFF71717A),
    outline: dark ? const Color(0xFF343846) : const Color(0xFFD4D4D8),
    outlineVariant: dark ? const Color(0xFF262934) : const Color(0xFFE4E4E7),
    error: dark ? const Color(0xFFF87171) : const Color(0xFFDC2626),
  );

  final radius = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
      surfaceTintColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 23,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: radius,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
  );
}
