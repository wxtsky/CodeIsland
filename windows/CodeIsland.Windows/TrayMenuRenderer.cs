using System.Drawing;
using System.Windows.Forms;

namespace CodeIsland.Windows;

public sealed class CodeIslandMenuColorTable : ProfessionalColorTable
{
    private static readonly Color Black = Color.FromArgb(8, 8, 9);
    private static readonly Color Surface = Color.FromArgb(24, 24, 26);
    private static readonly Color Border = Color.FromArgb(48, 48, 52);
    public override Color ToolStripDropDownBackground => Black;
    public override Color ImageMarginGradientBegin => Black;
    public override Color ImageMarginGradientMiddle => Black;
    public override Color ImageMarginGradientEnd => Black;
    public override Color MenuBorder => Border;
    public override Color MenuItemBorder => Color.FromArgb(57, 228, 110);
    public override Color MenuItemSelected => Surface;
    public override Color MenuItemSelectedGradientBegin => Surface;
    public override Color MenuItemSelectedGradientEnd => Surface;
    public override Color SeparatorDark => Border;
    public override Color SeparatorLight => Black;
}

public sealed class CodeIslandMenuRenderer : ToolStripProfessionalRenderer
{
    private static readonly Color Surface = Color.FromArgb(24, 24, 26);
    private static readonly Color Green = Color.FromArgb(57, 228, 110);
    public CodeIslandMenuRenderer() : base(new CodeIslandMenuColorTable()) { }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        var bounds = new Rectangle(1, 1, e.Item.Width - 2, e.Item.Height - 2);
        using var brush = new SolidBrush(e.Item.Selected ? Surface : Color.FromArgb(8, 8, 9));
        e.Graphics.FillRectangle(brush, bounds);
        if (e.Item.Selected) using (var pen = new Pen(Green)) e.Graphics.DrawRectangle(pen, bounds);
    }
}

public static class TrayMenuFactory
{
    public static ContextMenuStrip Create(string language, Action open, Action collapse, Action settings, Action diagnostics, Action exit)
    {
        var menu = new ContextMenuStrip
        {
            BackColor = Color.FromArgb(8, 8, 9),
            ForeColor = Color.FromArgb(232, 232, 235),
            Font = new Font("Cascadia Mono", 9.5f, FontStyle.Bold),
            Renderer = new CodeIslandMenuRenderer(),
            ShowImageMargin = false,
            ShowCheckMargin = false,
            DropShadowEnabled = true,
            Padding = new Padding(5)
        };
        menu.ItemAdded += (_, e) =>
        {
            if (e.Item is ToolStripMenuItem item)
            {
                item.AutoSize = false; item.Size = new Size(210, 34); item.Padding = new Padding(12, 0, 8, 0); item.Margin = new Padding(0, 1, 0, 1);
                item.BackColor = Color.FromArgb(8, 8, 9); item.ForeColor = Color.FromArgb(232, 232, 235);
            }
        };
        menu.Items.Add(L10n.Get("TrayOpenText", language), null, (_, _) => open());
        menu.Items.Add(L10n.Get("TrayCollapseText", language), null, (_, _) => collapse());
        menu.Items.Add(L10n.Get("TraySettingsText", language), null, (_, _) => settings());
        menu.Items.Add(L10n.Get("TrayDiagnosticsText", language), null, (_, _) => diagnostics());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L10n.Get("TrayExitText", language), null, (_, _) => exit());
        return menu;
    }
}
