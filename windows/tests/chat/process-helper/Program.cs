if (args is not ["close-stdout-overflow-stderr"])
{
    return 2;
}

Console.Out.Close();
while (true)
{
    Console.Error.Write(new string('e', 4096));
}
