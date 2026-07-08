using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class NotificationsSettingsViewModelTests
{
    [Fact]
    public void Defaults_MatchControllerSettings()
    {
        var vm = new NotificationsSettingsViewModel();
        Assert.True(vm.LocalEnabled);
        Assert.False(vm.TelegramEnabled);
        Assert.Equal(string.Empty, vm.TelegramBotToken);
        Assert.Equal(string.Empty, vm.TelegramChatId);
        Assert.True(vm.CalendarEnabled);
        Assert.Equal(30, vm.CalendarDefaultMinutes);
        Assert.Equal(180, vm.DefaultSnoozeMinutes);
    }

    [Fact]
    public void TelegramFields_OnlyShowWhenEnabled()
    {
        var vm = new NotificationsSettingsViewModel();
        Assert.False(vm.ShowTelegramFields);
        vm.TelegramEnabled = true;
        Assert.True(vm.ShowTelegramFields);
    }

    [Fact]
    public void IsTelegramConfigured_RequiresTokenAndChatId()
    {
        var vm = new NotificationsSettingsViewModel { TelegramEnabled = true };
        Assert.False(vm.IsTelegramConfigured);
        vm.TelegramBotToken = "bot-token";
        Assert.False(vm.IsTelegramConfigured);
        vm.TelegramChatId = "12345";
        Assert.True(vm.IsTelegramConfigured);
    }

    [Fact]
    public void MinuteFields_FloorBelowFifteenToTheirDefault()
    {
        var vm = new NotificationsSettingsViewModel();
        vm.CalendarDefaultMinutes = 5;
        Assert.Equal(30, vm.CalendarDefaultMinutes);
        vm.DefaultSnoozeMinutes = 1;
        Assert.Equal(180, vm.DefaultSnoozeMinutes);

        vm.CalendarDefaultMinutes = 45;
        Assert.Equal(45, vm.CalendarDefaultMinutes);
        vm.DefaultSnoozeMinutes = 120;
        Assert.Equal(120, vm.DefaultSnoozeMinutes);
    }

    [Fact]
    public void MinuteChoices_MatchThePickerSets()
    {
        var vm = new NotificationsSettingsViewModel();
        Assert.Equal(new[] { 15, 30, 45, 60, 90 }, vm.CalendarMinutesChoices);
        Assert.Equal(new[] { 30, 60, 90, 120, 180, 240 }, vm.SnoozeMinutesChoices);
    }

    [Fact]
    public void CapabilityNotes_FlagTelegramDeferAndCalendarNotApplicable()
    {
        var vm = new NotificationsSettingsViewModel();
        Assert.Contains("row 16", vm.TelegramCapabilityNote);
        Assert.Contains("row 17", vm.CalendarCapabilityNote);
    }

    [Fact]
    public void LoadClamp_FixesOutOfRangeStoredMinutes()
    {
        var store = new InMemoryNotificationSettingsStore(
            new NotificationSettingsSnapshot(true, false, "", "", true, 3, 2));
        var vm = new NotificationsSettingsViewModel(store);
        Assert.Equal(30, vm.CalendarDefaultMinutes);
        Assert.Equal(180, vm.DefaultSnoozeMinutes);
    }

    [Fact]
    public void Mutations_PersistThroughStore()
    {
        var store = new InMemoryNotificationSettingsStore();
        var vm = new NotificationsSettingsViewModel(store);
        vm.LocalEnabled = false;
        vm.TelegramEnabled = true;
        vm.TelegramBotToken = "t";
        vm.TelegramChatId = "c";
        vm.CalendarEnabled = false;
        vm.CalendarDefaultMinutes = 60;
        vm.DefaultSnoozeMinutes = 240;

        var reloaded = new NotificationsSettingsViewModel(store);
        Assert.False(reloaded.LocalEnabled);
        Assert.True(reloaded.TelegramEnabled);
        Assert.Equal("t", reloaded.TelegramBotToken);
        Assert.Equal("c", reloaded.TelegramChatId);
        Assert.False(reloaded.CalendarEnabled);
        Assert.Equal(60, reloaded.CalendarDefaultMinutes);
        Assert.Equal(240, reloaded.DefaultSnoozeMinutes);
    }
}
