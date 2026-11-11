# -*- coding: utf-8 -*-
"""
Generate a ConditionalReader file from the video bookmarks

This macro takes the list of the current video bookmarks and generates a
new text file to be used with ConditionalReader.  Each frame can represent a
single frame or the start or end of a range of frames.  If the 'interpolation'
option is selected (only valid for int and float), 'Value' must consist in
two space-separated values.

If a bookmark have a title, it can be used as its value instead of the one
introduced in the prompt dialog.  For ranges of frames, the value can be put
in the title of either the start or end frame.  When using interpolation the
two values can be introduced both in the same bookmark or separately.

More info on ConditionalReader:
http://avisynth.nl/index.php/ConditionalReader


Written by vdcrim
Original macro idea by Bernardd

GPo mod, @2021 fast and dirty, last change: 17.06.2021
    Generate a ConditionalReader file from WriteFile file
    read the input and:
        delete two '0' pings and reduce three '0' pings to one
"""

# PREFERENCES

default_type = 'Bool'
default_default = ''
default_value = ''
default_bm_meaning = 'Single frames'
default_insert_path = True


# ------------------------------------------------------------------------------


# Run in thread
import sys
import os.path

filename = avsp.GetFilename(title='Open WriteFile log', filefilter=_('Text files') +
                            ' (*.txt)|*.txt|' + _('All files') + ' (*.*)|*.*',  default='')
if not filename:
    return
if os.path.getsize(filename) > 1024 * 500:
    avsp.MsgBox('File size to big')
    return

fDir, fName = os.path.split(filename)
# set the default filename
default_filename = os.path.join(fDir, 'new_' + fName)

with open(filename, mode='rb') as f:
    txt = f.read()
    f.close()

lines = txt.strip().split('\n')
bmlist = []
c = 0
for line in lines:
    line = line.strip()
    if not line:
        continue
    if line.startswith('0'):
        c += 1
        if c > 2: # change here the threshold
            nr = line.split(' ')
            if len(nr) == 2:
                bmlist.append((nr[0], nr[1]))
            else:
                bmlist.append((line, ''))
            c = 0
    else:
        nr = line.split(' ')
        if len(nr) == 2:
            bmlist.append((nr[0], nr[1]))
        else:
            bmlist.append((line, ''))
        c = 0

if not bmlist:
    avsp.MsgBox(_('There is not Valus'), _('Error'))
    return

# Prompt for options
if not default_filename:
    default_filename = os.path.splitext(avsp.GetScriptFilename(propose='general'))[0]

txt_filter = (_('Text files') + ' (*.txt)|*.txt|' + _('All files') + '|*.*')
while True:
    options = avsp.GetTextEntry(
        title=_('ConditionalReader file from WriteFile file'),
        message=[[_('Type'), _('Default'), _('Value')],
                 _('ConditionalReader file'),
                 _('Insert the ConditionalReader file path at the current '
                   'cursor position')
                ],
        default=[[(_('Bool'), _('Int'), _('Float'), _('String'), default_type),
                  (_('True'), _('False'), default_default),
                  (_('True'), _('False'), default_value)],
                 (default_filename, txt_filter), default_insert_path
                ],
        types=[['list_read_only', 'list_writable', 'list_writable'], 'file_save', 'check'], width=415)
    if not options:
        return
    typ, default, value, filename, insert_path = options
    if not filename:
        avsp.MsgBox(_('An output path is needed'), _('Error'))
    else: break

    (default_typ, default_default, default_value,
     default_filename, default_insert_path) = options

# Write the ConditionalReader file
value_default = value.strip()
text = ['Type {0}\n'.format(typ)]
if default: text.append(u'Default {0}\n'.format(default.strip()))

for frame, title in bmlist:
    text.append(u'{0} {1}\n'.format(frame,
        title.strip() if title else value_default))


text = [line.encode(sys.getfilesystemencoding()) for line in text]
with open(filename, 'w') as file:
    file.writelines(text)
if insert_path:
    avsp.InsertText(u'"{0}"'.format(filename), pos=None)

