/** Design tokens mirrored from the Flutter app. Each token cites its source. */
export const tokens = {
  color: {
    primary: '#00838F', // mobile/lib/main.dart:86-87
    primaryDark: '#004D40', // mobile/lib/main.dart:2085
    route: '#00BCD4', // mobile/lib/main.dart:1023-1026
    routeAlternative: '#94A3B8', // mobile/lib/main.dart:1005-1013
    issueStatus: {
      GREEN: '#22C55E', // mobile/lib/main.dart:206-210
      BLUE: '#3B82F6', // mobile/lib/main.dart:214-218
      YELLOW: '#EAB308', // mobile/lib/main.dart:222-226
      ORANGE: '#F97316', // mobile/lib/main.dart:230-234
      RED: '#EF4444', // mobile/lib/main.dart:238-242
    },
    issueDetailStatus: {
      GREEN: '#1B8A5A', // mobile/lib/widgets/issue_detail_sheet.dart:657-658
      BLUE: '#1F6FEB', // mobile/lib/widgets/issue_detail_sheet.dart:659-660
      YELLOW: '#B58105', // mobile/lib/widgets/issue_detail_sheet.dart:661-662
      ORANGE: '#D97706', // mobile/lib/widgets/issue_detail_sheet.dart:663-664
      RED: '#D9342B', // mobile/lib/widgets/issue_detail_sheet.dart:665-666
    },
    condition: {
      clean: '#1B8A5A', // mobile/lib/widgets/survey_sheets.dart:36
      good: '#4D9A4D', // mobile/lib/widgets/survey_sheets.dart:37
      normal: '#B58105', // mobile/lib/widgets/survey_sheets.dart:38
      bad: '#D97706', // mobile/lib/widgets/survey_sheets.dart:39
      worst: '#D9342B', // mobile/lib/widgets/survey_sheets.dart:40
    },
    slate: {
      50: '#F1F5F9', // mobile/lib/main.dart:1647
      300: '#CBD5E1', // mobile/lib/main.dart:1649
      700: '#334155', // mobile/lib/main.dart:1671
      500: '#64748B', // mobile/lib/main.dart:1680
      800: '#1E293B', // mobile/lib/main.dart:1717
      900: '#0F172A', // mobile/lib/main.dart:1747
    },
    routeWarning: {
      background: '#FFF7ED', // mobile/lib/main.dart:1785
      icon: '#EA580C', // mobile/lib/main.dart:1796
      text: '#9A3412', // mobile/lib/main.dart:1807
    },
    routeSuccess: {
      background: '#F0FDF4', // mobile/lib/main.dart:1785
      icon: '#16A34A', // mobile/lib/main.dart:1796
      text: '#166534', // mobile/lib/main.dart:1808
    },
  },
  /** Flutter does not provide darkTheme; seed-based M3 roles stay framework-derived. */
  colorScheme: {
    light: { seed: '#00838F' }, // mobile/lib/main.dart:86-88
    dark: { seed: '#00838F' }, // mobile/lib/main.dart:86-88; no explicit darkTheme is declared
  },
  /** No LinearGradient is declared in the inspected Flutter UI. */
  gradients: {},
  shadow: {
    card: '0 2px 4px rgba(0, 0, 0, 0.26)', // mobile/lib/main.dart:2088 (black26, blur 4, y offset 2)
  },
  radius: {
    progress: '4px', // mobile/lib/widgets/survey_sheets.dart:911
    pillSmall: '9px', // mobile/lib/widgets/survey_sheets.dart:1448
    control: '10px', // mobile/lib/main.dart:1690
    tile: '12px', // mobile/lib/main.dart:1733
    card: '14px', // mobile/lib/main.dart:1824
    sheet: '16px', // mobile/lib/widgets/issue_detail_sheet.dart:553
    pill: '20px', // mobile/lib/widgets/issue_detail_sheet.dart:620
    chatComposer: '24px', // mobile/lib/screens/chat_screen.dart:627
  },
  spacing: {
    xs: '4px', // mobile/lib/main.dart:1711
    sm: '8px', // mobile/lib/widgets/survey_sheets.dart:940
    md: '12px', // mobile/lib/widgets/survey_sheets.dart:1083
    lg: '14px', // mobile/lib/main.dart:2392
    xl: '16px', // mobile/lib/screens/chat_screen.dart:348
    xxl: '18px', // mobile/lib/widgets/survey_sheets.dart:871
    xxxl: '20px', // mobile/lib/widgets/issue_detail_sheet.dart:316
    huge: '24px', // mobile/lib/widgets/issue_detail_sheet.dart:316
  },
  type: {
    micro: '10px', // mobile/lib/main.dart:1715
    tiny: '11px', // mobile/lib/main.dart:1669
    small: '12px', // mobile/lib/screens/chat_screen.dart:454
    body: '13px', // mobile/lib/widgets/survey_sheets.dart:1280
    bodyLarge: '14px', // mobile/lib/main.dart:1989
    compactBody: '12.5px', // mobile/lib/widgets/survey_sheets.dart:1240
    title: '22px', // Material 3 titleLarge use in mobile/lib/widgets/survey_sheets.dart:883 (font size comes from M3)
    family: 'Roboto, Arial, sans-serif', // Flutter Material default: mobile/lib/main.dart:86
  },
} as const

export type IssueStatusColor = keyof typeof tokens.color.issueStatus
