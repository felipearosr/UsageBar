// ESLint flat config for the GNOME extension, adapted from the rules GNOME
// Shell lints its own JS with (gnome-shell lint/eslintrc-gjs.yml and
// eslintrc-shell.yml). CI runs it as a warning-only report next to the EGO
// ZIP lint; it has no package.json and no plugins, so any eslint@9 can load it:
//
//   npx --yes eslint@9 --config linux/usagebar-gnome/eslint.config.mjs \
//       linux/usagebar-gnome/usagebar@felipearosr.github.io

const gjsGlobals = Object.fromEntries([
    'ARGV', 'Debugger', 'GIRepositoryGType', 'clearInterval', 'clearTimeout',
    'console', 'global', 'globalThis', 'imports', 'log', 'logError', 'pkg',
    'print', 'printerr', 'setInterval', 'setTimeout', 'TextDecoder',
    'TextEncoder', 'URL',
].map(name => [name, 'readonly']));

export default [
    {
        files: ['**/*.js'],
        languageOptions: {
            ecmaVersion: 2024,
            sourceType: 'module',
            globals: gjsGlobals,
        },
        rules: {
            // Correctness (eslint:recommended subset GNOME Shell keeps on).
            'no-dupe-class-members': 'warn',
            'no-dupe-keys': 'warn',
            'no-duplicate-imports': 'warn',
            'no-empty': ['warn', {allowEmptyCatch: true}],
            'no-redeclare': 'warn',
            'no-self-assign': 'warn',
            'no-undef': 'warn',
            'no-unreachable': 'warn',
            'no-unused-vars': ['warn', {
                args: 'none',
                varsIgnorePattern: '^_',
                caughtErrors: 'none',
            }],
            'no-use-before-define': ['warn', {functions: false, classes: true, variables: true}],
            // GJS style.
            'arrow-parens': ['warn', 'as-needed'],
            'block-scoped-var': 'warn',
            'brace-style': ['warn', '1tbs', {allowSingleLine: true}],
            'comma-dangle': ['warn', 'always-multiline'],
            'curly': ['warn', 'multi-or-nest', 'consistent'],
            'eqeqeq': ['warn', 'smart'],
            'no-var': 'warn',
            'prefer-arrow-callback': 'warn',
            'prefer-const': 'warn',
            'quotes': ['warn', 'single', {avoidEscape: true}],
            'semi': ['warn', 'always'],
        },
    },
];
