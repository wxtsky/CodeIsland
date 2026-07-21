using System.Media;
using CodeIsland.Core;

namespace CodeIsland.Windows;

public enum NotificationCue { None, Start, Approval, Complete, Error }

public sealed class NotificationSoundManager
{
    public bool Enabled { get; set; } = true;

    public static NotificationCue CueFor(AgentEventType eventType) => eventType switch
    {
        AgentEventType.SessionStart => NotificationCue.Start,
        AgentEventType.PermissionRequest or AgentEventType.Question => NotificationCue.Approval,
        AgentEventType.SessionEnd => NotificationCue.Complete,
        AgentEventType.Error => NotificationCue.Error,
        _ => NotificationCue.None
    };

    public void Play(AgentEvent agentEvent)
    {
        if (!Enabled) return;
        switch (CueFor(agentEvent.Type))
        {
            case NotificationCue.Start: SystemSounds.Asterisk.Play(); break;
            case NotificationCue.Approval: SystemSounds.Exclamation.Play(); break;
            case NotificationCue.Complete: SystemSounds.Beep.Play(); break;
            case NotificationCue.Error: SystemSounds.Hand.Play(); break;
        }
    }
}
