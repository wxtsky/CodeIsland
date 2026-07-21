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

public static class TrayMenuFactory
{
    public static ContextMenuStrip Create()
    {
        var menu = new ContextMenuStrip
        {
            BackColor = Color.FromArgb(8, 8, 9),
            ForeColor = Color.FromArgb(232, 232, 235),
            Font = new Font("Cascadia Mono", 9.5f, FontStyle.Bold),
            Renderer = new ToolStripProfessionalRenderer(new CodeIslandMenuColorTable()),
            ShowImageMargin = false,
            ShowCheckMargin = false,
            DropShadowEnabled = true,
            Padding = new Padding(5)
        };
        menu.ItemAdded += (_, e) =>
        {
            if (e.Item is ToolStripMenuItem item)
            {
                item.AutoSize = false;
                item.Size = new Size(210, 34);
                item.Padding = new Padding(12, 0, 8, 0);
                item.Margin = new Padding(0, 1, 0, 1);
            }
        };
        return menu;
    }
}
