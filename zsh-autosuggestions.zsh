# Fish-like fast/unobtrusive autosuggestions for zsh.
# https://github.com/zsh-users/zsh-autosuggestions
# v0.2.17
# Copyright (c) 2013 Thiago de Arruda
# Copyright (c) 2016 Eric Freese
# 
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

#--------------------------------------------------------------------#
# Global Configuration Variables                                     #
#--------------------------------------------------------------------#

# Color to use when highlighting suggestion
# Uses format of `region_highlight`
# More info: http://zsh.sourceforge.net/Doc/Release/Zsh-Line-Editor.html#Zle-Widgets
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'

# Prefix to use when saving original versions of bound widgets
ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX=autosuggest-orig-

# Widgets that clear the suggestion
ZSH_AUTOSUGGEST_CLEAR_WIDGETS=(
    history-search-forward
    history-search-backward
    history-beginning-search-forward
    history-beginning-search-backward
    history-substring-search-up
    history-substring-search-down
    up-line-or-history
    down-line-or-history
    accept-line
)

# Widgets that accept the entire suggestion
ZSH_AUTOSUGGEST_ACCEPT_WIDGETS=(
    forward-char
    end-of-line
    vi-forward-char
    vi-end-of-line
)

# Widgets that accept the suggestion as far as the cursor moves
ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS=(
    forward-word
    vi-forward-word
    vi-forward-word-end
    vi-forward-blank-word
    vi-forward-blank-word-end
)

zmodload zsh/mapfile
zmodload zsh/sched

_zsh_autosuggest_sched_remove() {
    local sched_id
    while true; do
        sched_id=${zsh_scheduled_events[(I)*:*:$1]}
        (( $sched_id )) || break
        sched -$sched_id &> /dev/null
    done
}

_zsh_autosuggest_with_timeout() {
    emulate -LR zsh -o no_monitor
    local stat_reply
    local -F time_limit=$1
    shift
    (eval $@) &

    # TODO: /proc probably isn't portable
    zstat -A stat_reply '+mtime' /proc/$!

    local PID=$! START_TIME=$SECONDS MTIME=${stat_reply[1]}
    while true; do
        sleep 0.001
        if [[ ! -d /proc/$PID ]]; then
            break
        fi
        zstat -A stat_reply '+mtime' /proc/$PID
        if (( ${stat_reply[1]} != $MTIME )); then
            break
        fi
        if (( $SECONDS - $START_TIME > $time_limit )); then
            {
                kill -1 $PID
                wait $PID
            } 2> /dev/null
            break
        fi
    done
}

#--------------------------------------------------------------------#
# Handle Deprecated Variables/Widgets                                #
#--------------------------------------------------------------------#

_zsh_autosuggest_deprecated_warning() {
    >&2 echo "zsh-autosuggestions: $@"
}

_zsh_autosuggest_check_deprecated_config() {
    if [ -n "$AUTOSUGGESTION_HIGHLIGHT_COLOR" ]; then
        _zsh_autosuggest_deprecated_warning "AUTOSUGGESTION_HIGHLIGHT_COLOR is deprecated. Use ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE instead."
        [ -z "$ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE" ] && ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE=$AUTOSUGGESTION_HIGHLIGHT_STYLE
        unset AUTOSUGGESTION_HIGHLIGHT_STYLE
    fi

    if [ -n "$AUTOSUGGESTION_HIGHLIGHT_CURSOR" ]; then
        _zsh_autosuggest_deprecated_warning "AUTOSUGGESTION_HIGHLIGHT_CURSOR is deprecated."
        unset AUTOSUGGESTION_HIGHLIGHT_CURSOR
    fi

    if [ -n "$AUTOSUGGESTION_ACCEPT_RIGHT_ARROW" ]; then
        _zsh_autosuggest_deprecated_warning "AUTOSUGGESTION_ACCEPT_RIGHT_ARROW is deprecated. The right arrow now accepts the suggestion by default."
        unset AUTOSUGGESTION_ACCEPT_RIGHT_ARROW
    fi
}

_zsh_autosuggest_deprecated_start_widget() {
    _zsh_autosuggest_deprecated_warning "The autosuggest-start widget is deprecated. For more info, see the README at https://github.com/zsh-users/zsh-autosuggestions."
    zle -D autosuggest-start
    eval "zle-line-init() {
        $(echo $functions[${widgets[zle-line-init]#*:}] | sed -e 's/zle autosuggest-start//g')
    }"
}

zle -N autosuggest-start _zsh_autosuggest_deprecated_start_widget

#--------------------------------------------------------------------#
# Widget Helpers                                                     #
#--------------------------------------------------------------------#

# Bind a single widget to an autosuggest widget, saving a reference to the original widget
_zsh_autosuggest_bind_widget() {
    local widget=$1
    local autosuggest_action=$2
    local prefix=$ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX

    # Save a reference to the original widget
    case $widgets[$widget] in
        # Already bound
        (user:_zsh_autosuggest_(bound|orig)_*);;

        # User-defined widget
        (user:*)
            zle -N $prefix$widget ${widgets[$widget]#*:}
            ;;

        # Built-in widget
        (builtin)
            eval "_zsh_autosuggest_orig_$widget() { zle .$widget }"
            zle -N $prefix$widget _zsh_autosuggest_orig_$widget
            ;;

        # Completion widget
        (completion:*)
            eval "zle -C $prefix$widget ${${widgets[$widget]#*:}/:/ }"
            ;;
    esac

    # Pass the original widget's name explicitly into the autosuggest
    # function. Use this passed in widget name to call the original
    # widget instead of relying on the $WIDGET variable being set
    # correctly. $WIDGET cannot be trusted because other plugins call
    # zle without the `-w` flag (e.g. `zle self-insert` instead of
    # `zle self-insert -w`).
    eval "_zsh_autosuggest_bound_$widget() {
        _zsh_autosuggest_widget_$autosuggest_action $prefix$widget \$@
    }"

    # Create the bound widget
    zle -N $widget _zsh_autosuggest_bound_$widget
}

# Map all configured widgets to the right autosuggest widgets
_zsh_autosuggest_bind_widgets() {
    local widget;

    # Find every widget we might want to bind and bind it appropriately
    for widget in ${${(f)"$(builtin zle -la)"}:#(.*|_*|orig-*|autosuggest-*|$ZSH_AUTOSUGGEST_ORIGINAL_WIDGET_PREFIX*|zle-line-*|run-help|which-command|beep|set-local-history|yank)}; do
        if [ ${ZSH_AUTOSUGGEST_CLEAR_WIDGETS[(r)$widget]} ]; then
            _zsh_autosuggest_bind_widget $widget clear
        elif [ ${ZSH_AUTOSUGGEST_ACCEPT_WIDGETS[(r)$widget]} ]; then
            _zsh_autosuggest_bind_widget $widget accept
        elif [ ${ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS[(r)$widget]} ]; then
            _zsh_autosuggest_bind_widget $widget partial_accept
        else
            # Assume any unspecified widget might modify the buffer
            _zsh_autosuggest_bind_widget $widget modify
        fi
    done
}

# Given the name of an original widget and args, invoke it, if it exists
_zsh_autosuggest_invoke_original_widget() {
    # Do nothing unless called with at least one arg
    [ $# -gt 0 ] || return

    local original_widget_name=$1

    shift

    if [ $widgets[$original_widget_name] ]; then
        zle $original_widget_name -- $@
    fi
}

#--------------------------------------------------------------------#
# Highlighting                                                       #
#--------------------------------------------------------------------#

# If there was a highlight, remove it
_zsh_autosuggest_highlight_reset() {
    if [ -n "$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT" ]; then
        region_highlight=("${(@)region_highlight:#$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT}")
        unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT
    fi
}

# If there's a suggestion, highlight it
_zsh_autosuggest_highlight_apply() {
    if [ $#POSTDISPLAY -gt 0 ]; then
        _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT="$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) $ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE"
        region_highlight+=("$_ZSH_AUTOSUGGEST_LAST_HIGHLIGHT")
    else
        unset _ZSH_AUTOSUGGEST_LAST_HIGHLIGHT
    fi
}

#--------------------------------------------------------------------#
# Suggestion                                                         #
#--------------------------------------------------------------------#

# Get a suggestion from history that matches a given prefix
_zsh_autosuggest_suggestion_helper() {
    emulate -LR zsh -o extended_glob

    local prefix="${@}"
    local -a recent=(${"${(f)mapfile[$HISTFILE]}"#: [0-9]##:0;})

    # Echo the first item that matches
    local result=${recent[(R)$prefix*]}
    echo -E $result
}

_zsh_autosuggest_suggestion() {
    _zsh_autosuggest_with_timeout 1 "_zsh_autosuggest_suggestion_helper ${(q)@}"
}

_zle_synchronize_postdisplay() {
    if [[ -n $POSTDISPLAY_INTERNAL && -n $BUFFER ]]; then
        local suffix=${POSTDISPLAY_INTERNAL##$BUFFER}
        if [[ $suffix != $POSTDISPLAY_INTERNAL ]]; then
            POSTDISPLAY=${POSTDISPLAY_INTERNAL#$BUFFER}
        else
            # The POSTDISPLAY is out-of-date so recompute it
            unset POSTDISPLAY
            _zsh_autosuggest_worker_start
        fi
    else
        unset POSTDISPLAY
    fi

    # Force the highlighting to take place immediately
    _zsh_autosuggest_highlight_apply
    zle -R
}

zle -N _zle_synchronize_postdisplay

_zsh_autosuggest_callback() {
    if [[ $5 == zsh_suggest:zle\ -F*returned\ error* ]]; then
        _zsh_autosuggest_worker_setup
        return
    fi

    # Add the suggestion to the POSTDISPLAY proxy variable
    # We can't modify ZLE variables in this callback, but
    # We can through ZLE widgets.
    POSTDISPLAY_INTERNAL=$3
    _zsh_autosuggest_sched_remove _zsh_autosuggest_worker_timeout
    _zsh_autosuggest_sched_remove _zsh_autosuggest_worker_check

    zle && zle _zle_synchronize_postdisplay
}

_zsh_autosuggest_with_protected_return_code() {
    local return=$?
    "$@"
    return $return
}

_zsh_autosuggest_worker_check() {
    _zsh_autosuggest_with_protected_return_code \
        async_process_results zsh_suggest _zsh_autosuggest_callback
}

_zsh_autosuggest_worker_setup() {
    async_start_worker zsh_suggest -u
    async_register_callback zsh_suggest _zsh_autosuggest_callback
}

_zsh_autosuggest_worker_cleanup() {
    async_stop_worker zsh_suggest
}

_zsh_autosuggest_worker_reset() {
    async_flush_jobs zsh_suggest
}

_zsh_autosuggest_worker_timeout() {
    _zsh_autosuggest_worker_reset
}

_zsh_autosuggest_worker_start() {
    if [[ -n $BUFFER ]]; then
        async_job zsh_suggest _zsh_autosuggest_suggestion $BUFFER
    fi

    sched +1 _zsh_autosuggest_worker_check
    sched +9 _zsh_autosuggest_worker_check

    sched +10 _zsh_autosuggest_worker_timeout
}

#--------------------------------------------------------------------#
# Autosuggest Widget Implementations                                 #
#--------------------------------------------------------------------#

# Clear the suggestion
_zsh_autosuggest_clear() {
    # Remove the suggestion
    unset POSTDISPLAY

    _zsh_autosuggest_invoke_original_widget $@
}

# Modify the buffer and get a new suggestion
_zsh_autosuggest_modify() {
    # Original widget modifies the buffer
    _zsh_autosuggest_invoke_original_widget $@

    # Get a new suggestion if the buffer is not empty after modification
    local suggestion
    zle _zle_synchronize_postdisplay
    _zsh_autosuggest_worker_start
}

# Accept the entire suggestion
_zsh_autosuggest_accept() {
    # Only accept if the cursor is at the end of the buffer
    if (( $CURSOR == $#BUFFER )); then
        # Add the suggestion to the buffer
        BUFFER="$BUFFER$POSTDISPLAY"

        # Remove the suggestion
        unset POSTDISPLAY

        # Move the cursor to the end of the buffer
        CURSOR=${#BUFFER}
    fi

    _zsh_autosuggest_invoke_original_widget $@
}

# Partially accept the suggestion
_zsh_autosuggest_partial_accept() {
    # Save the contents of the buffer so we can restore later if needed
    local original_buffer=$BUFFER

    # Temporarily accept the suggestion.
    BUFFER="$BUFFER$POSTDISPLAY"

    # Original widget moves the cursor
    _zsh_autosuggest_invoke_original_widget $@

    # If we've moved past the end of the original buffer
    if (( $CURSOR > $#original_buffer )); then
        # Set POSTDISPLAY to text right of the cursor
        POSTDISPLAY=$RBUFFER

        # Clip the buffer at the cursor
        BUFFER=$LBUFFER
    else
        # Restore the original buffer
        BUFFER=$original_buffer
    fi
}

for action in clear modify accept partial_accept; do
    eval "_zsh_autosuggest_widget_$action() {
        _zsh_autosuggest_highlight_reset
        _zsh_autosuggest_$action \$@
        _zsh_autosuggest_highlight_apply
    }"
done

zle -N autosuggest-accept _zsh_autosuggest_widget_accept
zle -N autosuggest-clear _zsh_autosuggest_widget_clear

#--------------------------------------------------------------------#
# Start                                                              #
#--------------------------------------------------------------------#

# Start the autosuggestion widgets
_zsh_autosuggest_start() {
    _zsh_autosuggest_check_deprecated_config
    _zsh_autosuggest_bind_widgets
}

async_init
_zsh_autosuggest_worker_setup

autoload -Uz add-zsh-hook
add-zsh-hook precmd _zsh_autosuggest_start
