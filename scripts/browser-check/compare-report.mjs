import {readFile, writeFile} from 'node:fs/promises';
import {compareCaptures} from './compare.mjs';

const [referencePath, playbackPath, outputPath] = process.argv.slice(2);
if (!referencePath || !playbackPath || !outputPath) throw new Error('Usage: node compare-report.mjs KEYBOARD_EXPORT.json NATIVE_CAPTURE.json REPORT.json');
const referenceFile = JSON.parse(await readFile(referencePath, 'utf8'));
const playbackFile = JSON.parse(await readFile(playbackPath, 'utf8'));
const report = compareCaptures(referenceFile.reference ?? referenceFile, playbackFile.playback ?? playbackFile);
await writeFile(outputPath, JSON.stringify(report, null, 2));
console.log(JSON.stringify({comparable: report.comparable, eventPropertiesMatch: report.eventPropertiesMatch,
  differingEvents: report.differingEvents, sharedKeyGroups: report.keyProperties.sharedGroups,
  differingKeyGroups: report.keyProperties.differingGroups, playbackVariant: report.playbackVariant,
  reasons: report.reasons, output: outputPath}, null, 2));
// A structural difference is a finding, not a tool execution failure.
process.exitCode = report.comparable ? 0 : 1;
