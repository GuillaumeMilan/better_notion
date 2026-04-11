use colored::{ColoredString, Colorize};

pub trait Decorate: std::fmt::Display {
    fn deco_as_error(&self) -> String {
        format!("{} {}", "[error]".bright_red().bold(), self)
    }

    fn deco_as_success(&self) -> ColoredString {
        self.to_string().green().bold()
    }

    fn deco_as_path(&self) -> ColoredString {
        self.to_string().bright_green()
    }

}

impl Decorate for String {}
impl Decorate for &str {}

pub fn explain(verbose: &bool, message: &str) {
    if *verbose {
        println!("{} {}", "[debug]".dimmed(), message);
    }
}
