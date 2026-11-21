import type { Config } from 'tailwindcss'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        civic: {
          teal: '#00838F', // mobile/lib/main.dart:86-87 (Material seed)
          darkTeal: '#004D40', // mobile/lib/main.dart:2085
          cyan: '#00BCD4', // mobile/lib/main.dart:1023-1026
          alternative: '#94A3B8', // mobile/lib/main.dart:1005-1013
        },
        severity: {
          green: '#22C55E', // mobile/lib/main.dart:206-210
          blue: '#3B82F6', // mobile/lib/main.dart:214-218
          yellow: '#EAB308', // mobile/lib/main.dart:222-226
          orange: '#F97316', // mobile/lib/main.dart:230-234
          red: '#EF4444', // mobile/lib/main.dart:238-242
        },
        'issue-status': {
          green: '#1B8A5A', // mobile/lib/widgets/issue_detail_sheet.dart:657-658
          blue: '#1F6FEB', // mobile/lib/widgets/issue_detail_sheet.dart:659-660
          yellow: '#B58105', // mobile/lib/widgets/issue_detail_sheet.dart:661-662
          orange: '#D97706', // mobile/lib/widgets/issue_detail_sheet.dart:663-664
          red: '#D9342B', // mobile/lib/widgets/issue_detail_sheet.dart:665-666
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
          500: '#64748B', // mobile/lib/main.dart:1680
          700: '#334155', // mobile/lib/main.dart:1671
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
        surface: '#F1F5F9', // mobile/lib/main.dart:1647
        outline: '#CBD5E1', // mobile/lib/main.dart:1649
        foreground: '#0F172A', // mobile/lib/main.dart:1747
        muted: '#64748B', // mobile/lib/main.dart:1680
      },
      borderRadius: {
        'progress': '4px', // mobile/lib/widgets/survey_sheets.dart:911
        'pill-sm': '9px', // mobile/lib/widgets/survey_sheets.dart:1448
        'control': '10px', // mobile/lib/main.dart:1690
        'tile': '12px', // mobile/lib/main.dart:1733
        'card': '14px', // mobile/lib/main.dart:1824
        'sheet': '16px', // mobile/lib/widgets/issue_detail_sheet.dart:553
        'pill': '20px', // mobile/lib/widgets/issue_detail_sheet.dart:620
        'composer': '24px', // mobile/lib/screens/chat_screen.dart:627
      },
      spacing: {
        'flutter-1': '4px', // mobile/lib/main.dart:1711
        'flutter-2': '8px', // mobile/lib/widgets/survey_sheets.dart:940
        'flutter-3': '12px', // mobile/lib/widgets/survey_sheets.dart:1083
        'flutter-35': '14px', // mobile/lib/main.dart:2392
        'flutter-4': '16px', // mobile/lib/screens/chat_screen.dart:348
        'flutter-45': '18px', // mobile/lib/widgets/survey_sheets.dart:871
        'flutter-5': '20px', // mobile/lib/widgets/issue_detail_sheet.dart:316
        'flutter-6': '24px', // mobile/lib/widgets/issue_detail_sheet.dart:316
      },
      fontSize: {
        'flutter-micro': '10px', // mobile/lib/main.dart:2385
        'flutter-tiny': '11px', // mobile/lib/main.dart:1669
        'flutter-small': '12px', // mobile/lib/screens/chat_screen.dart:454
        'flutter-body': '13px', // mobile/lib/widgets/survey_sheets.dart:1280
        'flutter-body-lg': '14px', // mobile/lib/main.dart:1989
        'flutter-compact': '12.5px', // mobile/lib/widgets/survey_sheets.dart:1240
        'flutter-title': '22px', // Material 3 titleLarge use: mobile/lib/widgets/survey_sheets.dart:883
      },
      boxShadow: {
        'flutter-card': '0 2px 4px rgba(0, 0, 0, 0.26)', // mobile/lib/main.dart:2088
      },
      fontFamily: {
        sans: ['Roboto', 'Arial', 'sans-serif'], // Flutter Material default: mobile/lib/main.dart:86
      },
    },
  },
  plugins: [],
} satisfies Config
