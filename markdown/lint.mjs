// Lints Markdown with markdownlint's library and exactly one configuration,
// which markdownlint-cli cannot: it merges rc files, /etc, HOME and the cwd's
// .markdownlint.* beneath --config. Output and exit status follow the CLI.
//
// Usage: node lint.mjs [--fix] MODULES CONFIG FILE...
// MODULES is the closure's node_modules directory; FILEs are relative to the
// cwd. Exit 0 clean, 1 findings, 4 any error (printed as "lint-md: ...").
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';

const fsOptions = {encoding: 'utf8'};

try {
    const args = process.argv.slice(2);
    const fix = args[0] === '--fix';
    const [modules, configFile, ...files] = fix ? args.slice(1) : args;
    if (!configFile) {
        throw new Error('usage: lint.mjs [--fix] MODULES CONFIG FILE...');
    }

    const require = createRequire(modules + '/');
    const load = name => import(pathToFileURL(require.resolve(name)).href);
    const {lint, readConfig} = await load('markdownlint/sync');
    const {applyFixes} = await load('markdownlint');
    const {parse, printParseErrorCode} = await load('jsonc-parser');
    const {default: ignore} = await load('ignore');

    // The CLI's own JSONC reader.
    const jsoncParse = text => {
        const errors = [];
        const result = parse(text, errors, {allowTrailingComma: true});
        if (errors.length > 0) {
            throw new Error('Unable to parse JSON(C) content, ' + errors.map(error => `${printParseErrorCode(error.error)} (offset ${error.offset}, length ${error.length})`).join(', '));
        }

        return result;
    };

    const configParsers = [jsoncParse];
    const config = readConfig(configFile, configParsers);
    const ignored = existsSync('.markdownlintignore') ? ignore().add(readFileSync('.markdownlintignore', fsOptions)) : null;
    const kept = files.filter(file => !ignored?.ignores(file));
    let status = 0;
    if (kept.length > 0) {
        const options = {config, configParsers, files: kept};
        if (fix) {
            for (const file of kept) {
                const fixes = lint({...options, files: [file]})[file].filter(error => error.fixInfo);
                if (fixes.length > 0) {
                    const original = readFileSync(file, fsOptions);
                    const fixed = applyFixes(original, fixes);
                    if (original !== fixed) {
                        writeFileSync(file, fixed, fsOptions);
                    }
                }
            }
        }

        const results = Object.entries(lint(options)).flatMap(([file, found]) => found.map(result => ({
            file,
            lineNumber: result.lineNumber,
            column: result.errorRange?.[0] || 0,
            names: result.ruleNames.join('/'),
            description: result.ruleDescription + (result.errorDetail ? ' [' + result.errorDetail + ']' : '') + (result.errorContext ? ' [Context: "' + result.errorContext + '"]' : ''),
            severity: result.severity,
        })));
        results.sort((a, b) => a.file.localeCompare(b.file) || a.lineNumber - b.lineNumber || a.names.localeCompare(b.names) || a.description.localeCompare(b.description));
        if (results.length > 0) {
            console.error(results.map(r => `${r.file}:${r.lineNumber}${r.column ? ':' + r.column : ''} ${r.severity} ${r.names} ${r.description}`).join('\n'));
        }

        status = results.some(result => result.severity === 'error') ? 1 : 0;
    }

    process.exitCode = status;
} catch (error) {
    console.error('lint-md: ' + (error?.message ?? error));
    process.exitCode = 4;
}
