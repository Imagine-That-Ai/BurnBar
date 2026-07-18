using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Settings.ViewModels.Daemon;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>
/// Production settings leaf for every tab with a portable view-model catalog entry.
/// Replaces empty-leaf fallthrough for S1/S2 tabs.
/// </summary>
public sealed partial class SettingsViewModelHostPage : Page
{
    private static readonly HashSet<string> CommandNames = new(StringComparer.Ordinal)
    {
        "CopyEndpoint", "SubmitEmail", "ClearError", "UpgradeToPremium", "SignOut",
        "DeleteAccount", "TriggerBackup", "Summon", "StartSession", "EndSession",
        "RefreshReadiness", "RunBrowserCheck", "ValidateChain", "ExportArchive", "Notarize",
        "CompletePermissionsSetup", "SaveDraft", "CancelDraft", "NewDraft",
    };

    private object? _viewModel;

    public SettingsViewModelHostPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        SettingsTab tab = SettingsTab.General;
        if (e.Parameter is SettingsPageContext ctx)
        {
            tab = ctx.Tab;
        }

        TitleText.Text = SettingsTabMetadata.Title(tab);
        SubtitleText.Text = SettingsTabMetadata.Subtitle(tab);

        SettingsTabViewModelDescriptor? descriptor = SettingsTabViewModelCatalog.Descriptors
            .FirstOrDefault(d => d.Tab == tab);

        if (descriptor is null)
        {
            GatingPill.Text = "No portable view-model";
            BodyText.Text = "This tab is not in SettingsTabViewModelCatalog.";
            DynamicControls.Children.Clear();
            return;
        }

        GatingPill.Text = Availability(tab, descriptor);

        _viewModel = SettingsViewModelFactory.Create(tab);
        BodyText.Text = tab == SettingsTab.ModelProxy
            ? "Changes save automatically. Restart the local runtime to apply endpoint and credential changes."
            : descriptor.Gating == SettingsTabViewModelGating.Live
                ? "Changes save automatically and take effect for the Windows runtime."
                : "Account-backed controls remain disabled until the required sign-in or device capability is available.";
        BuildControls(_viewModel);
    }

    private void BuildControls(object? viewModel)
    {
        DynamicControls.Children.Clear();
        SaveStatus.IsOpen = false;
        if (viewModel is null)
        {
            AddReadOnlyRow("Status", "No settings model is available for this tab.");
            return;
        }

        foreach (PropertyInfo property in viewModel.GetType().GetProperties(BindingFlags.Instance | BindingFlags.Public)
                     .Where(property => property.GetIndexParameters().Length == 0)
                     .OrderBy(property => property.MetadataToken))
        {
            if (!IsSupportedProperty(property.PropertyType)) continue;
            AddPropertyControl(viewModel, property);
        }

        foreach (MethodInfo method in viewModel.GetType().GetMethods(BindingFlags.Instance | BindingFlags.Public)
                     .Where(method => CommandNames.Contains(method.Name)))
        {
            if (method.GetParameters().Length == 0)
            {
                AddCommandButton(viewModel, method, Array.Empty<object?>(), Humanize(method.Name));
            }
        }

        MethodInfo? linkProvider = viewModel.GetType().GetMethod("LinkProvider", new[] { typeof(AuthProviderAction) });
        if (linkProvider is not null)
        {
            foreach (AuthProviderAction provider in Enum.GetValues<AuthProviderAction>())
            {
                AddCommandButton(viewModel, linkProvider, new object?[] { provider }, $"Sign in with {provider}");
            }
        }

        if (viewModel is ModelProxySettingsViewModel modelProxy)
        {
            AddModelProxyRouteControls(modelProxy);
            AddModelProxyRestartButton(viewModel);
        }
    }

    private void AddPropertyControl(object viewModel, PropertyInfo property)
    {
        string label = Humanize(property.Name);
        object? value;
        try
        {
            value = property.GetValue(viewModel);
        }
        catch (Exception ex)
        {
            AddReadOnlyRow(label, "Unavailable: " + ex.GetBaseException().Message);
            return;
        }

        if (!property.CanWrite || property.SetMethod?.IsPublic != true)
        {
            if (property.PropertyType == typeof(string) && value is string text && !string.IsNullOrWhiteSpace(text))
                AddReadOnlyRow(label, IsSecret(property.Name) ? "Configured" : text);
            else if (property.PropertyType == typeof(bool))
                AddReadOnlyRow(label, (bool?)value == true ? "On" : "Off");
            return;
        }

        Control control;
        if (property.PropertyType == typeof(bool))
        {
            var toggle = new ToggleSwitch { IsOn = value is true, OffContent = "Off", OnContent = "On" };
            toggle.Toggled += (_, _) => TrySet(viewModel, property, toggle.IsOn);
            control = toggle;
        }
        else if (property.PropertyType == typeof(string))
        {
            if (IsSecret(property.Name))
            {
                var password = new PasswordBox { Password = value as string ?? string.Empty, MaxWidth = 420 };
                password.PasswordChanged += (_, _) => TrySet(viewModel, property, password.Password);
                control = password;
            }
            else
            {
                var text = new TextBox { Text = value as string ?? string.Empty, MaxWidth = 420 };
                text.LostFocus += (_, _) => TrySet(viewModel, property, text.Text);
                control = text;
            }
        }
        else if (property.PropertyType == typeof(int) || property.PropertyType == typeof(double)
                 || property.PropertyType == typeof(int?) || property.PropertyType == typeof(double?))
        {
            var number = new NumberBox
            {
                Value = value is null ? double.NaN : Convert.ToDouble(value, CultureInfo.InvariantCulture),
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
                MaxWidth = 220,
            };
            number.ValueChanged += (_, args) =>
            {
                object? converted = double.IsNaN(args.NewValue)
                    ? null
                    : property.PropertyType is var type && (type == typeof(int) || type == typeof(int?))
                        ? checked((int)Math.Round(args.NewValue))
                        : args.NewValue;
                TrySet(viewModel, property, converted);
            };
            control = number;
        }
        else
        {
            Type enumType = Nullable.GetUnderlyingType(property.PropertyType) ?? property.PropertyType;
            var combo = new ComboBox { MinWidth = 220, ItemsSource = Enum.GetValues(enumType) };
            combo.SelectedItem = value;
            combo.SelectionChanged += (_, _) => TrySet(viewModel, property, combo.SelectedItem);
            control = combo;
        }

        AutomationProperties.SetName(control, label);
        AddRow(label, control);
    }

    private void AddCommandButton(object viewModel, MethodInfo method, object?[] arguments, string label)
    {
        PropertyInfo? canExecute = viewModel.GetType().GetProperty(
            "Can" + method.Name,
            BindingFlags.Instance | BindingFlags.Public);
        bool isEnabled = canExecute?.PropertyType != typeof(bool)
            || canExecute.GetValue(viewModel) is true;
        var button = new Button
        {
            Content = label,
            HorizontalAlignment = HorizontalAlignment.Left,
            IsEnabled = isEnabled,
        };
        AutomationProperties.SetName(button, label);
        button.Click += async (_, _) => await InvokeCommandAsync(viewModel, method, arguments, button);
        DynamicControls.Children.Add(button);
    }

    private void AddModelProxyRestartButton(object viewModel)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(new SymbolIcon(Symbol.Refresh));
        content.Children.Add(new TextBlock { Text = "Restart local runtime" });
        var button = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(button, "Restart local runtime");
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try
            {
                await App.Current.RestartLocalGatewayAsync();
                BuildControls(viewModel);
                ShowSuccess("The local model runtime restarted with the saved settings.");
            }
            catch (Exception ex)
            {
                ShowError(ex.GetBaseException().Message);
            }
            finally
            {
                button.IsEnabled = true;
            }
        };
        DynamicControls.Children.Add(button);
    }

    private void AddModelProxyRouteControls(ModelProxySettingsViewModel viewModel)
    {
        var header = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 12, 0, 2) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var heading = new StackPanel { Spacing = 2 };
        heading.Children.Add(new TextBlock
        {
            Text = "Provider routes",
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        heading.Children.Add(new TextBlock
        {
            Text = $"{viewModel.ProviderRoutes.ReadyCount} ready of {viewModel.ProviderRoutes.ConfiguredCount} configured",
            Opacity = 0.65,
            FontSize = 12,
        });
        var addContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        addContent.Children.Add(new SymbolIcon(Symbol.Add));
        addContent.Children.Add(new TextBlock { Text = "Add route" });
        var addButton = new Button { Content = addContent, HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetName(addButton, "Add provider route");
        addButton.Click += async (_, _) => await ShowGatewayRouteDialogAsync(viewModel, existing: null);
        Grid.SetColumn(heading, 0);
        Grid.SetColumn(addButton, 1);
        header.Children.Add(heading);
        header.Children.Add(addButton);
        DynamicControls.Children.Add(header);

        if (!string.IsNullOrWhiteSpace(viewModel.ProviderRoutes.LastError))
        {
            AddReadOnlyRow("Provider route error", viewModel.ProviderRoutes.LastError);
        }

        if (viewModel.ProviderRoutes.Routes.Count == 0)
        {
            AddReadOnlyRow("Route status", "No upstream provider routes are configured.");
            return;
        }

        foreach (GatewayRouteSettingsRow route in viewModel.ProviderRoutes.Routes)
        {
            var row = new Grid
            {
                ColumnSpacing = 12,
                Padding = new Thickness(0, 8, 0, 8),
            };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var identity = new StackPanel { Spacing = 3 };
            identity.Children.Add(new TextBlock
            {
                Text = $"{route.Vendor} / {route.Model}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            identity.Children.Add(new TextBlock
            {
                Text = route.Endpoint,
                FontFamily = Theme.BrandFonts.Mono,
                FontSize = 11,
                Opacity = 0.72,
                TextWrapping = TextWrapping.Wrap,
            });
            identity.Children.Add(new TextBlock
            {
                Text = $"{route.Status} · priority {route.Priority} · {route.Authentication}",
                FontSize = 11,
                Opacity = 0.65,
            });

            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var enabled = new ToggleSwitch
            {
                IsOn = route.Enabled,
                OffContent = "Off",
                OnContent = "On",
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(enabled, $"Enable {route.Vendor} {route.Model} route");
            enabled.Toggled += async (_, _) =>
            {
                enabled.IsEnabled = false;
                GatewayRouteMutationResult result = viewModel.ProviderRoutes.SetEnabled(route.Id, enabled.IsOn);
                if (!result.Succeeded)
                {
                    ShowError(result.Error ?? "The route could not be updated.");
                    BuildControls(viewModel);
                    return;
                }

                await RestartAfterRouteChangeAsync(viewModel, "Provider route updated.");
            };

            var edit = new Button { Content = new SymbolIcon(Symbol.Edit) };
            AutomationProperties.SetName(edit, $"Edit {route.Vendor} {route.Model} route");
            ToolTipService.SetToolTip(edit, "Edit route");
            edit.Click += async (_, _) => await ShowGatewayRouteDialogAsync(viewModel, route);

            var delete = new Button { Content = new SymbolIcon(Symbol.Delete) };
            AutomationProperties.SetName(delete, $"Delete {route.Vendor} {route.Model} route");
            ToolTipService.SetToolTip(delete, "Delete route");
            delete.Click += async (_, _) => await DeleteGatewayRouteAsync(viewModel, route);

            actions.Children.Add(enabled);
            actions.Children.Add(edit);
            actions.Children.Add(delete);
            Grid.SetColumn(identity, 0);
            Grid.SetColumn(actions, 1);
            row.Children.Add(identity);
            row.Children.Add(actions);
            DynamicControls.Children.Add(row);
            DynamicControls.Children.Add(new Border
            {
                Height = 1,
                Opacity = 0.12,
                Background = new SolidColorBrush(Microsoft.UI.Colors.White),
            });
        }
    }

    private async Task ShowGatewayRouteDialogAsync(
        ModelProxySettingsViewModel viewModel,
        GatewayRouteSettingsRow? existing)
    {
        var vendor = new TextBox { Header = "Provider", Text = existing?.Vendor ?? string.Empty };
        var model = new TextBox { Header = "Model", Text = existing?.Model ?? string.Empty };
        var endpoint = new TextBox { Header = "Completion endpoint", Text = existing?.Endpoint ?? "https://" };
        var priority = new NumberBox
        {
            Header = "Priority",
            Value = existing?.Priority ?? viewModel.ProviderRoutes.ConfiguredCount,
            Minimum = 0,
            Maximum = GatewayRouteConfiguration.MaximumPriority,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
        };
        var authentication = new ComboBox
        {
            Header = "Authentication",
            ItemsSource = Enum.GetValues<GatewayRouteAuthentication>(),
            SelectedItem = existing?.Authentication ?? GatewayRouteAuthentication.Bearer,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var credential = new PasswordBox
        {
            Header = "Bearer credential",
            PlaceholderText = existing?.CredentialConfigured == true
                ? "Protected credential configured; blank keeps it"
                : "Required when Bearer is selected",
        };
        var enabled = new ToggleSwitch
        {
            Header = "Route enabled",
            IsOn = existing?.Enabled ?? true,
            OffContent = "Off",
            OnContent = "On",
        };
        var error = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            IsClosable = false,
            IsOpen = false,
        };
        var content = new StackPanel { Spacing = 10, MinWidth = 420 };
        content.Children.Add(vendor);
        content.Children.Add(model);
        content.Children.Add(endpoint);
        content.Children.Add(priority);
        content.Children.Add(authentication);
        content.Children.Add(credential);
        content.Children.Add(enabled);
        content.Children.Add(error);

        bool saved = false;
        var dialog = new ContentDialog
        {
            Title = existing is null ? "Add provider route" : "Edit provider route",
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            int parsedPriority = double.IsNaN(priority.Value)
                ? -1
                : checked((int)Math.Round(priority.Value));
            var input = new GatewayRouteInput(
                existing?.Id,
                vendor.Text,
                model.Text,
                endpoint.Text,
                parsedPriority,
                enabled.IsOn,
                authentication.SelectedItem is GatewayRouteAuthentication selected
                    ? selected
                    : GatewayRouteAuthentication.Bearer,
                credential.Password);
            GatewayRouteMutationResult result = viewModel.ProviderRoutes.Upsert(input);
            if (!result.Succeeded)
            {
                args.Cancel = true;
                error.Message = result.Error ?? "The route could not be saved.";
                error.IsOpen = true;
                return;
            }

            saved = true;
        };

        await dialog.ShowAsync();
        if (saved)
        {
            await RestartAfterRouteChangeAsync(viewModel, "Provider route saved and local runtime restarted.");
        }
    }

    private async Task DeleteGatewayRouteAsync(
        ModelProxySettingsViewModel viewModel,
        GatewayRouteSettingsRow route)
    {
        var dialog = new ContentDialog
        {
            Title = "Delete provider route",
            Content = $"Delete {route.Vendor} / {route.Model} and its protected credential from this PC?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        GatewayRouteMutationResult result = viewModel.ProviderRoutes.Delete(route.Id);
        if (!result.Succeeded)
        {
            ShowError(result.Error ?? "The route could not be deleted.");
            return;
        }

        await RestartAfterRouteChangeAsync(viewModel, "Provider route deleted and local runtime restarted.");
    }

    private async Task RestartAfterRouteChangeAsync(
        ModelProxySettingsViewModel viewModel,
        string successMessage)
    {
        try
        {
            await App.Current.RestartLocalGatewayAsync();
            BuildControls(viewModel);
            ShowSuccess(successMessage);
        }
        catch (Exception ex)
        {
            BuildControls(viewModel);
            ShowError("The route was saved, but the local runtime could not restart: "
                + ex.GetBaseException().Message);
        }
    }

    private async Task InvokeCommandAsync(object viewModel, MethodInfo method, object?[] arguments, Button button)
    {
        button.IsEnabled = false;
        try
        {
            if (viewModel is ComputerUseSettingsViewModel computerUse)
            {
                if (method.Name == "StartSession")
                {
                    if (!computerUse.IsReady)
                    {
                        throw new InvalidOperationException("Computer Use permissions are not ready.");
                    }
                    await App.Current.ClearComputerUsePanicAsync();
                }
                else if (method.Name == "EndSession")
                {
                    await App.Current.ActivateComputerUsePanicAsync(
                        "user_halt",
                        OpenBurnBar.ComputerUse.Core.Gate.ComputerUsePanicSource.Revoked);
                }
            }
            object? result = await Task.Run(() => method.Invoke(viewModel, arguments));
            if (result is Task task)
            {
                await task;
                Type taskType = task.GetType();
                result = taskType.IsGenericType
                    ? taskType.GetProperty("Result")?.GetValue(task)
                    : null;
            }
            if (result is bool success && !success)
            {
                ShowError("The action could not complete. Check the account or capability status above.");
            }
            else
            {
                BuildControls(viewModel);
            }
        }
        catch (Exception ex)
        {
            ShowError(ex.GetBaseException().Message);
        }
        finally
        {
            button.IsEnabled = true;
        }
    }

    private void TrySet(object viewModel, PropertyInfo property, object? value)
    {
        try
        {
            property.SetValue(viewModel, value);
            SaveStatus.IsOpen = false;
        }
        catch (Exception ex)
        {
            ShowError(ex.GetBaseException().Message);
        }
    }

    private void AddReadOnlyRow(string label, string value) => AddRow(label, new TextBlock
    {
        Text = value,
        TextWrapping = TextWrapping.Wrap,
        Opacity = 0.72,
    });

    private void AddRow(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 16, Padding = new Thickness(0, 8, 0, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var title = new TextBlock
        {
            Text = label,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        Grid.SetColumn(title, 0);
        Grid.SetColumn(control, 1);
        grid.Children.Add(title);
        grid.Children.Add(control);
        DynamicControls.Children.Add(grid);
        DynamicControls.Children.Add(new Border
        {
            Height = 1,
            Opacity = 0.12,
            Background = new SolidColorBrush(Microsoft.UI.Colors.White),
        });
    }

    private void ShowError(string message)
    {
        SaveStatus.Severity = InfoBarSeverity.Error;
        SaveStatus.Message = message;
        SaveStatus.IsOpen = true;
    }

    private void ShowSuccess(string message)
    {
        SaveStatus.Severity = InfoBarSeverity.Success;
        SaveStatus.Message = message;
        SaveStatus.IsOpen = true;
    }

    private static bool IsSupportedProperty(Type type)
    {
        Type actual = Nullable.GetUnderlyingType(type) ?? type;
        return actual == typeof(bool) || actual == typeof(string) || actual == typeof(int)
            || actual == typeof(double) || actual.IsEnum;
    }

    private static bool IsSecret(string name) => name.Contains("Password", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Token", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Secret", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Key", StringComparison.OrdinalIgnoreCase);

    private static string Humanize(string name)
    {
        var builder = new StringBuilder(name.Length + 8);
        for (int i = 0; i < name.Length; i++)
        {
            char current = name[i];
            if (i > 0 && char.IsUpper(current) && !char.IsUpper(name[i - 1])) builder.Append(' ');
            builder.Append(current);
        }
        return builder.ToString();
    }

    private static string Availability(SettingsTab tab, SettingsTabViewModelDescriptor descriptor) => tab switch
    {
        SettingsTab.Account when !CloudAuthProductionComposition.IsOAuthConfigured() =>
            "Sign-in unavailable - OAuth client configuration is missing",
        SettingsTab.Pets => "Preferences persist - companion host activation is not yet available",
        _ when descriptor.Gating == SettingsTabViewModelGating.Live => "Live controls - saved on this device",
        _ => "Controls live - account data requires sign-in and App Check",
    };
}

/// <summary>Constructs portable settings view-models for WinUI host pages.</summary>
public static class SettingsViewModelFactory
{
    public static object? Create(SettingsTab tab) => WindowsSettingsComposition.Create(tab);

    public static IReadOnlyList<string> Describe(object? vm)
    {
        if (vm is null)
        {
            return new[] { "No view-model instance." };
        }

        var lines = new List<string> { "Type: " + vm.GetType().Name };
        if (vm is DaemonSettingsViewModel daemon)
        {
            lines.Add(daemon.FinishLineDefault);
            lines.Add(daemon.FinishLineExplainer);
            lines.Add(daemon.Summary.HeaderLine);
            lines.Add(daemon.Explainer);
            foreach (WindowsFinishLineScopeRow row in daemon.FinishLineScope.Take(8))
            {
                lines.Add($"F1/F2 · {row.Area}: {row.F1ShipPeer}");
            }
        }
        else if (vm is ObservableSettingsViewModel observable)
        {
            // Generic property dump of public string properties for honesty surface.
            foreach (var prop in observable.GetType().GetProperties()
                         .Where(p => p.CanRead && p.PropertyType == typeof(string)))
            {
                try
                {
                    object? val = prop.GetValue(observable);
                    if (val is string s && !string.IsNullOrWhiteSpace(s))
                    {
                        lines.Add($"{prop.Name}: {s}");
                    }
                }
                catch
                {
                    // skip
                }
            }
        }

        if (lines.Count == 1)
        {
            lines.Add("View-model constructed for production navigation (no empty leaf).");
        }

        return lines;
    }
}
