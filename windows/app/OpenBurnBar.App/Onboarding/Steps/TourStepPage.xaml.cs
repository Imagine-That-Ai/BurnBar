using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Product-tour step. Windows peer of <c>OnboardingTourView.swift</c>: a paged
/// glass card with dot navigation. The four sub-pages are walked by the bounds-guarded
/// chevrons (and the footer Continue) through the model, so the outer step only advances
/// once the last page is reached — exactly the Swift behavior.</summary>
public sealed partial class TourStepPage : Page
{
    private readonly record struct TourEntry(string Glyph, Color Tint, string Title, string Description);

    private static readonly TourEntry[] Pages =
    {
        new("D", Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06), "Dashboard",
            "Your burn rate at a glance. Token spend, model breakdown, cost trends — all from local logs, never phoning home."),
        new("L", Color.FromArgb(0xFF, 0xFF, 0x75, 0x78), "Session Logs",
            "Every conversation, searchable. Browse by provider, project, or time. Export markdown for your records."),
        new("P", Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C), "Projects",
            "Organize work by project, see spend and activity in one place, and keep context tied to what you're building."),
        new("H", Color.FromArgb(0xFF, 0xC7, 0xCF, 0xDD), "Hermes Chat",
            "Your local AI companion. Ask questions about your usage, search conversations, or let Hermes analyze your workflow patterns."),
    };

    private OnboardingContext? _context;

    public TourStepPage()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    private OnboardingWizardModel? Model => _context?.Model;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (Model is null)
        {
            return;
        }

        Model.PropertyChanged += OnModelChanged;
        Render();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingWizardModel.TourPage))
        {
            Render();
        }
    }

    private void Render()
    {
        if (Model is null)
        {
            return;
        }

        int index = System.Math.Clamp(Model.TourPage, 0, Pages.Length - 1);
        TourEntry page = Pages[index];

        TourBadge.Background = new SolidColorBrush(page.Tint);
        TourBadgeGlyph.Text = page.Glyph;
        TourTitle.Text = page.Title;
        TourDescription.Text = page.Description;

        PrevButton.IsEnabled = index > 0;
        NextButton.IsEnabled = index < Pages.Length - 1;

        Dots.Children.Clear();
        for (int i = 0; i < Pages.Length; i++)
        {
            bool active = i == index;
            Dots.Children.Add(new Ellipse
            {
                Width = active ? 8 : 6,
                Height = active ? 8 : 6,
                Fill = active
                    ? new SolidColorBrush(Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06))
                    : (Brush)Application.Current.Resources["OBBStrokeBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
    }

    // Bounds-guarded: these only walk sub-pages (never advance the step), matching the
    // Swift tour chevrons; the model's NavigateForward/Back handle the sub-page move.
    private void OnPrev(object sender, RoutedEventArgs e)
    {
        if (Model is { TourPage: > 0 })
        {
            Model.NavigateBack();
        }
    }

    private void OnNext(object sender, RoutedEventArgs e)
    {
        if (Model is not null && Model.TourPage < OnboardingWizardModel.TourPageCount - 1)
        {
            Model.NavigateForward();
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (Model is not null)
        {
            Model.PropertyChanged -= OnModelChanged;
        }
    }
}
