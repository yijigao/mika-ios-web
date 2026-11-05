#!/usr/bin/env python3
"""STEER-FOLD source guards against dispatch baseline; does not execute Swift."""
from pathlib import Path
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'dc5424626152396347b540de1b77cfb47bcc2f8f'
os.chdir(ROOT)


def original(path):
    return subprocess.check_output(['git', 'show', BASE + ':' + path], text=True)


def function(source, name):
    match = re.search(r'\bfunc ' + name + r'\s*\(', source)
    assert match, name
    begin = source.index('{', match.end())
    depth, end = 1, begin + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


def validate():
    engine = Path('MikaWeb/AgentEngine.swift').read_text()
    baseline = original('MikaWeb/AgentEngine.swift')
    for name in ['advanceQueue', 'stop', 'stopFromUser', 'finishTask',
                 'finishTaskFromUser', 'confirm', 'submitAnswer']:
        assert function(engine, name) == function(baseline, name), name
        print('PASS: protected function unchanged:', name)
    counter = 'stepBudget.consumeDecision()'
    assert engine.count(counter) == baseline.count(counter) == 1
    current, previous = engine.index(counter), baseline.index(counter)
    assert engine[current - 80:current + 80] == baseline[previous - 80:previous + 80]
    print('PASS: single model step counting point and surrounding code unchanged')
    for path in ['MikaWeb/WebController.swift', 'MikaWeb/SafetyPolicy.swift']:
        assert Path(path).read_text() == original(path), path
        print('PASS: unchanged:', path)
    chat = Path('MikaWeb/AgentChatView.swift').read_text()
    old_chat = original('MikaWeb/AgentChatView.swift')
    assert '.onChange(of: conversation.entries.count)' in chat
    for name in ['shouldFollow', 'verify']:
        assert function(chat, name) == function(old_chat, name), name
    print('PASS: SESSION-UX policy/self-check unchanged; follow trigger still entries.count')
    send = function(chat[chat.index('struct ChatInputBar:'):], 'send')
    order = [send.index(marker) for marker in [
        'if canQueue', 'if questionID == nil, hasLiveSession', 'if let questionID',
        'else if canThreeWay', 'else if isNewTask']]
    assert order == sorted(order)
    print('PASS: send branch order canQueue -> continuation -> answer -> running-only steer -> new task')
    tests = Path('MikaWeb/SelfTestView.swift').read_text()
    old_tests = original('MikaWeb/SelfTestView.swift')
    labels = re.findall(r'Button\("(自检[^"\\]*)"', old_tests)
    assert all(label in tests for label in labels)
    assert '自检四十三' in tests and '自检四十四' in tests
    for name in re.findall(r'\bfunc (\w+)\s*\(', old_tests):
        assert function(tests, name) == function(old_tests, name), name
    print('PASS: existing SelfTestView buttons and test method bodies preserved; 43/44 added')
    store = Path('MikaWeb/AgentConversationStore.swift').read_text()
    old_store = original('MikaWeb/AgentConversationStore.swift')
    for name in ['route', 'switchDisplayedSession', 'syncTaskTracking', 'append',
                 'flushBatch', 'persistNow', 'appendToFile', 'loadPersisted',
                 'fileContains', 'trimHistory']:
        assert function(store, name) == function(old_store, name), name
    print('PASS: conversation routing, step tracking, batching, persistence, trimming unchanged')
    print('NOTE: source invariant checks only; Swift verify methods were not executed')


if __name__ == '__main__':
    validate()
